{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts #-}

{-|
The canister interface, presented imperatively (or impurely), i.e. without rollback
-}
module IC.Canister.Imp
 ( ESRef
 , ImpState(..)
 , runESST
 , rawInitialize
 , rawInvoke
 , silently
 )
where

import qualified Data.ByteString.Lazy as BS
import qualified Data.ByteString.Lazy.Char8 as BSC
import qualified Data.ByteString.Lazy.UTF8 as BSU
import Control.Monad.Primitive
import Control.Monad.ST
import Control.Monad.Except
import Data.STRef
import Data.Maybe
import Data.Int -- TODO: Should be Word32 in most cases

import IC.Types
import IC.Wasm.Winter
import IC.Wasm.WinterMemory as Mem
import IC.Wasm.Imports
import qualified IC.Canister.Interface as CI

-- Parameters are the data that come from the caller

data Params = Params
  { param_dat  :: Maybe Blob
  , param_caller :: Maybe EntityId
  , reject_code :: Int
  , reject_message :: String
  }

-- The execution state is all information available to the
-- canister. Some of it is immutable (could be separated here)

data ExecutionState s = ExecutionState
  { inst :: Instance s
  , stableMem :: Memory s
  , self_id :: CanisterId
  , params :: Params
  -- now the mutable parts
  , responded :: Responded
  , response :: Maybe Response
  , reply_data :: Blob
  , calls :: [MethodCall]
  }


initalExecutionState :: CanisterId -> Instance s -> Memory s -> Responded -> ExecutionState s
initalExecutionState self_id inst stableMem responded = ExecutionState
  { inst
  , stableMem
  , self_id
  , params = Params Nothing Nothing 0 ""
  , responded
  , response = Nothing
  , reply_data = mempty
  , calls = mempty
  }

-- Some bookkeeping to access the ExecutionState
--
-- We “always” have the 'STRef', but only within 'withES' is it actually
-- present.
--
-- Also: A flag to check whether we are running in silent mode or not
-- (a bit of a hack)

type ESRef s = (STRef s Bool, STRef s (Maybe (ExecutionState s)))

newESRef :: ST s (ESRef s)
newESRef = (,) <$> newSTRef True <*> newSTRef Nothing

runESST :: (forall s. ESRef s -> ST s a) -> a
runESST f = runST $ newESRef >>= f

-- | runs a computation with the given initial execution state
-- and returns the final execution state with it.
withES :: PrimMonad m =>
  ESRef (PrimState m) ->
  ExecutionState (PrimState m) ->
  m a -> m (a, ExecutionState (PrimState m))
withES (_pref, esref) es f = do
  before <- stToPrim $ readSTRef esref
  unless (isNothing before) $ error "withES with non-empty es"
  stToPrim $ writeSTRef esref $ Just es
  x <- f
  es' <- stToPrim $ readSTRef esref
  case es' of
    Nothing -> error "withES: ExecutionState lost"
    Just es' -> do
      stToPrim $ writeSTRef esref Nothing
      return (x, es')

silently :: PrimMonad m => ESRef (PrimState m) -> m x -> m x
silently (pref, _esref) f = do
  before <- stToPrim $ readSTRef pref
  stToPrim $ writeSTRef pref False
  x <- f
  stToPrim $ writeSTRef pref before
  return x

getsES :: ESRef s -> (ExecutionState s -> b) -> HostM s b
getsES (_, esref) f = lift (readSTRef esref) >>= \case
  Nothing -> throwError "System API not available yet"
  Just es -> return (f es)

modES :: ESRef s -> (ExecutionState s -> ExecutionState s) -> HostM s ()
modES (_, esref) f = lift $ modifySTRef esref (fmap f)

appendReplyData :: ESRef s -> Blob -> HostM s ()
appendReplyData esref dat = modES esref $ \es ->
  es { reply_data = reply_data es <> dat }

setResponse :: ESRef s -> Response -> HostM s ()
setResponse esref r = modES esref $ \es ->
  es { response = Just r }

appendCall :: ESRef s -> MethodCall -> HostM s ()
appendCall esref c = modES esref $ \es ->
  es { calls = calls es ++ [c] }

-- The System API, with all imports

-- The code is defined in the where clause to scope over the 'ESRef'

systemAPI :: forall s. ESRef s -> Imports s
systemAPI esref =
  [ toImport "ic0" "msg_arg_data_size" msg_arg_data_size
  , toImport "ic0" "msg_arg_data_copy" msg_arg_data_copy
  , toImport "ic0" "msg_caller_size" msg_caller_size
  , toImport "ic0" "msg_caller_copy" msg_caller_copy
  , toImport "ic0" "msg_reject_code" msg_reject_code
  , toImport "ic0" "msg_reject_msg_size" msg_reject_msg_size
  , toImport "ic0" "msg_reject_msg_copy" msg_reject_msg_copy
  , toImport "ic0" "msg_reply_data_append" msg_reply_data_append
  , toImport "ic0" "msg_reply" msg_reply
  , toImport "ic0" "msg_reject" msg_reject
  , toImport "ic0" "canister_self_copy" canister_self_copy
  , toImport "ic0" "canister_self_size" canister_self_size
  , toImport "ic0" "call_simple" call_simple
  , toImport "ic0" "stable_size" stable_size
  , toImport "ic0" "stable_grow" stable_grow
  , toImport "ic0" "stable_write" stable_write
  , toImport "ic0" "stable_read" stable_read
  , toImport "ic0" "debug_print" debug_print
  , toImport "ic0" "trap" explicit_trap
  ]
  where
    -- Utilities
    gets :: (ExecutionState s -> b) -> HostM s b
    gets = getsES esref

    copy_to_canister :: Int32 -> Int32 -> Int32 -> Blob -> HostM s ()
    copy_to_canister dst offset size blob = do
      unless (offset == 0) $
        throwError "offset /= 0 not supported"
      unless (size == fromIntegral (BS.length blob)) $
        throwError "copying less than the full blob is not supported"
      i <- getsES esref inst
      -- TODO Bounds checking
      setBytes i (fromIntegral dst) blob

    copy_from_canister :: String -> Int32 -> Int32 -> HostM s Blob
    copy_from_canister _name src size = do
      i <- gets inst
      getBytes i (fromIntegral src) size

    size_and_copy :: HostM s Blob ->
      ( () -> HostM s Int32
      , (Int32, Int32, Int32) -> HostM s ()
      )
    size_and_copy get_blob =
      ( \() ->
        get_blob >>= \blob -> return $ fromIntegral (BS.length blob)
      , \(dst, offset, size) ->
        get_blob >>= \blob -> copy_to_canister dst offset size blob
      )

    -- Unsafely print (if not in silent mode)
    putBytes :: BS.ByteString -> HostM s ()
    putBytes bytes =
      stToPrim (readSTRef (fst esref)) >>= \case
        True -> unsafeIOToPrim $ BSC.putStrLn $ BSC.pack "debug.print: " <> bytes
        False -> return ()

    -- The system calls (in the order of the public spec)
    -- https://docs.dfinity.systems/spec/public/#_system_imports

    msg_arg_data_size :: () -> HostM s Int32
    msg_arg_data_copy :: (Int32, Int32, Int32) -> HostM s ()
    (msg_arg_data_size, msg_arg_data_copy) = size_and_copy $
        gets (param_dat . params) >>= maybe (throwError "No argument") return

    msg_caller_size :: () -> HostM s Int32
    msg_caller_copy :: (Int32, Int32, Int32) -> HostM s ()
    (msg_caller_size, msg_caller_copy) = size_and_copy $
        fmap rawEntityId $ gets (param_caller . params) >>= maybe (throwError "No argument") return

    msg_reject_code :: () -> HostM s Int32
    msg_reject_code () =
      fromIntegral <$> gets (reject_code . params)

    msg_reject_msg_size :: () -> HostM s Int32
    msg_reject_msg_copy :: (Int32, Int32, Int32) -> HostM s ()
    (msg_reject_msg_size, msg_reject_msg_copy) = size_and_copy $ do
      c <- gets (reject_code . params)
      when (c == 0) $ throwError "No reject message"
      msg <- gets (reject_message . params)
      return $ BSU.fromString msg

    assert_not_responded :: HostM s ()
    assert_not_responded = do
      gets responded >>= \case
        Responded False -> return ()
        Responded True  -> throwError "This call has already been responded to earlier"
      gets response >>= \case
        Nothing -> return ()
        Just  _ -> throwError "This call has already been responded to in this function"

    msg_reply_data_append :: (Int32, Int32) -> HostM s ()
    msg_reply_data_append (src, size) = do
      assert_not_responded
      bytes <- copy_from_canister "msg_reply_data_append" src size
      appendReplyData esref bytes

    msg_reply :: () -> HostM s ()
    msg_reply () = do
      assert_not_responded
      bytes <- gets reply_data
      setResponse esref (Reply bytes)

    msg_reject :: (Int32, Int32) -> HostM s ()
    msg_reject (src, size) = do
      assert_not_responded
      bytes <- copy_from_canister "msg_reject" src size
      let msg = BSU.toString bytes
      setResponse esref $ Reject (RC_CANISTER_REJECT, msg)

    canister_self_size :: () -> HostM s Int32
    canister_self_copy :: (Int32, Int32, Int32) -> HostM s ()
    (canister_self_size, canister_self_copy) = size_and_copy $
      rawEntityId <$> gets self_id

    call_simple ::
      ( Int32, Int32, Int32, Int32, Int32
      , Int32, Int32, Int32, Int32, Int32) -> HostM s Int32
    call_simple
      ( callee_src
      , callee_size
      , name_src
      , name_size
      , reply_fun
      , reply_env
      , reject_fun
      , reject_env
      , data_src
      , data_size
      ) = do
      callee <- copy_from_canister "call_simple" callee_src callee_size
      method_name <- copy_from_canister "call_simple" name_src name_size
      arg <- copy_from_canister "call_simple" data_src data_size

      appendCall esref $ MethodCall
        { call_callee = EntityId callee
        , call_method_name = BSU.toString method_name -- TODO: check for valid UTF8
        , call_arg = arg
        , call_callback = Callback
            { reply_callback = WasmClosure reply_fun reply_env
            , reject_callback = WasmClosure reject_fun reject_env
            }
        }
      return 0

    stable_size :: () -> HostM s Int32
    stable_size () = do
      m <- gets stableMem
      Mem.size m

    stable_grow :: Int32 -> HostM s Int32
    stable_grow delta = do
      m <- gets stableMem
      Mem.grow m delta

    stable_write :: (Int32, Int32, Int32) -> HostM s ()
    stable_write (dst, src, size) = do
      m <- gets stableMem
      i <- getsES esref inst
      blob <- getBytes i (fromIntegral src) size
      Mem.write m (fromIntegral dst) blob

    stable_read :: (Int32, Int32, Int32) -> HostM s ()
    stable_read (dst, src, size) = do
      m <- gets stableMem
      i <- getsES esref inst
      blob <- Mem.read m (fromIntegral src) size
      setBytes i (fromIntegral dst) blob


    debug_print :: (Int32, Int32) -> HostM s ()
    debug_print (src, size) = do
      -- TODO: This should be a non-trapping copy
      bytes <- copy_from_canister "debug_print" src size
      putBytes bytes

    explicit_trap :: (Int32, Int32) -> HostM s ()
    explicit_trap (src, size) = do
      -- TODO: This should be a non-trapping copy
      bytes <- copy_from_canister "trap" src size
      let msg = BSU.toString bytes
      throwError $ "canister trapped explicitly: " ++ msg

-- The state of an instance, consistig of the underlying Wasm state,
-- additional remembered information like the CanisterId
-- and the 'ESRef' that the system api functions are accessing

data ImpState s = ImpState
  { isESRef :: ESRef s
  , isCanisterId :: CanisterId
  , isInstance :: Instance s
  , isStableMem :: Memory s
  }

rawInitialize :: ESRef s -> CanisterId -> Module -> ST s (TrapOr (ImpState s))
rawInitialize esref cid wasm_mod = do
  result <- runExceptT $ (,)
    <$> initialize wasm_mod (systemAPI esref)
    <*> Mem.new
  case result of
    Left  err -> return $ Trap err
    Right (inst, sm) -> return $ Return $ ImpState esref cid inst sm

rawInvoke :: ImpState s -> CI.CanisterMethod r -> ST s (TrapOr r)
rawInvoke is (CI.Initialize wasm_mod caller dat) =
    rawInitializeMethod is wasm_mod caller dat
rawInvoke is (CI.Query name caller dat) =
    rawQueryMethod is name caller dat
rawInvoke is (CI.Update name caller responded dat) =
    rawUpdateMethod is name caller responded dat
rawInvoke is (CI.Callback cb responded res) =
    rawCallbackMethod is cb responded res
rawInvoke is (CI.PreUpgrade wasm_mod caller) =
    rawPreUpgrade is wasm_mod caller
rawInvoke is (CI.PostUpgrade wasm_mod caller mem dat) =
    rawPostUpgrade is wasm_mod caller mem dat

cantRespond :: Responded
cantRespond = Responded True

canRespond :: Responded
canRespond = Responded False

rawInitializeMethod :: ImpState s -> Module -> EntityId -> Blob -> ST s (TrapOr ())
rawInitializeMethod (ImpState esref cid inst sm) wasm_mod caller dat = do
  result <- runExceptT $ do
    let es = (initalExecutionState cid inst sm cantRespond)
              { params = Params
                  { param_dat    = Just dat
                  , param_caller = Just caller
                  , reject_code  = 0
                  , reject_message = ""
                  }
              }

    --  invoke canister_init
    if "canister_init" `elem` exportedFunctions wasm_mod
    then withES esref es $ void $ invokeExport inst "canister_init" []
    else return ((), es)

  case result of
    Left  err -> return $ Trap err
    Right (_, es')
        | null (calls es') -> return $ Return ()
        | otherwise        -> return $ Trap "cannot call from init"

rawPreUpgrade :: ImpState s -> Module -> EntityId -> ST s (TrapOr Blob)
rawPreUpgrade (ImpState esref cid inst sm) wasm_mod caller = do
  result <- runExceptT $ do
    let es = (initalExecutionState cid inst sm cantRespond)
              { params = Params
                  { param_dat    = Nothing
                  , param_caller = Just caller
                  , reject_code  = 0
                  , reject_message = ""
                  }
              }

    if "canister_pre_upgrade" `elem` exportedFunctions wasm_mod
    then withES esref es $ void $ invokeExport inst "canister_pre_upgrade" []
    else return ((), es)

  case result of
    Left  err -> return $ Trap err
    Right (_, es')
        | null (calls es') -> Return <$> Mem.export (stableMem es')
        | otherwise        -> return $ Trap "cannot call from pre_upgrade"

rawPostUpgrade :: ImpState s -> Module -> EntityId -> Blob -> Blob -> ST s (TrapOr ())
rawPostUpgrade (ImpState esref cid inst sm) wasm_mod caller mem dat = do
  result <- runExceptT $ do
    let es = (initalExecutionState cid inst sm cantRespond)
              { params = Params
                  { param_dat    = Just dat
                  , param_caller = Just caller
                  , reject_code  = 0
                  , reject_message = ""
                  }
              }
    lift $ Mem.imp (stableMem es) mem

    if "canister_post_upgrade" `elem` exportedFunctions wasm_mod
    then withES esref es $ void $ invokeExport inst "canister_post_upgrade" []
    else return ((), es)

  case result of
    Left  err -> return $ Trap err
    Right (_, es')
        | null (calls es') -> return $ Return ()
        | otherwise        -> return $ Trap "cannot call from post_upgrade"

rawQueryMethod :: ImpState s -> MethodName -> EntityId -> Blob -> ST s (TrapOr Response)
rawQueryMethod (ImpState esref cid inst sm) method caller dat = do
  let es = (initalExecutionState cid inst sm canRespond)
            { params = Params
                { param_dat    = Just dat
                , param_caller = Just caller
                , reject_code  = 0
                , reject_message = ""
                }
            }
  result <- runExceptT $ withES esref es $
    invokeExport inst ("canister_query " ++ method) []

  case result of
    Left err -> return $ Trap err
    Right (_, es')
      | not (null (calls es')) -> return $ Trap "cannot call from query"
      | Just r <- response es' -> return $ Return r
      | otherwise -> return $ Trap "No response"

rawUpdateMethod :: ImpState s -> MethodName -> EntityId -> Responded -> Blob -> ST s (TrapOr UpdateResult)
rawUpdateMethod (ImpState esref cid inst sm) method caller responded dat = do
  let es = (initalExecutionState cid inst sm responded)
            { params = Params
                { param_dat    = Just dat
                , param_caller = Just caller
                , reject_code  = 0
                , reject_message = ""
                }
            }

  result <- runExceptT $ withES esref es $
    invokeExport inst ("canister_update " ++ method) []
  case result of
    Left  err -> return $ Trap err
    Right (_, es') -> return $ Return (calls es', response es')

rawCallbackMethod :: ImpState s -> Callback -> Responded -> Response -> ST s (TrapOr UpdateResult)
rawCallbackMethod (ImpState esref cid inst sm) callback responded res = do
  let params = case res of
        Reply dat ->
          Params { param_dat = Just dat, param_caller = Nothing, reject_code = 0, reject_message = "" }
        Reject (rc, reject_message) ->
          Params { param_dat = Nothing, param_caller = Nothing, reject_code = rejectCode rc, reject_message }
  let es = (initalExecutionState cid inst sm responded) { params }

  let WasmClosure fun_idx env = case res of
        Reply {}  -> reply_callback callback
        Reject {} -> reject_callback callback

  result <- runExceptT $ withES esref es $
    invokeTable inst fun_idx [I32 env]
  case result of
    Left  err -> return $ Trap err
    Right (_, es') -> return $ Return (calls es', response es')

