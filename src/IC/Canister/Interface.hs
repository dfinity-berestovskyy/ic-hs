{-# LANGUAGE GADTs #-}

{-|
This module defines the various entry points provided by "IC.Canister.Imp" as a data type describing the arguments and results.

The point of this abstraction is to to allow adding new entry points, or changing the arguments or result values, without changing the modules "IC.Canister.Pure" or "IC.Canister.Persisted", that sit between "IC.Canister.Imp" and "IC.Canister".

Certain features here are beyond the specified abilities, in order to support the Motoko test suite. In particular:

 * Creating canisters
 * Issuing calls from canister_init

-}
module IC.Canister.Interface where

import IC.Types
import IC.Wasm.Winter (Module)


data CanisterMethod r where
    Initialize :: ExistingCanisters -> Module -> EntityId -> Blob -> CanisterMethod InitResult
    Query :: MethodName -> EntityId -> Blob -> CanisterMethod Response
    Update :: MethodName -> ExistingCanisters -> EntityId -> Blob -> CanisterMethod UpdateResult
    Callback :: Callback -> ExistingCanisters -> EntityId -> Response -> CanisterMethod UpdateResult
