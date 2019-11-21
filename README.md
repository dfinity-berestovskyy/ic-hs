The IC Stub
===========

The IC stub is a partial implementation of the public interface of the DFINITY
Internet Computer, as specified in
https://docs.dfinity.systems/spec/public/
with the primary goal of providing a mock environment to test the output of the
Motoko compiler.

It currently provides one binary, `ic-stub-run`, that allows you to script the
execution of a single canister.

Status
------

This is neither complete nor authoritative. Since this is primarily meant for
testing the output of Motoko, code paths not exercised by Motoko may not be
present; in particular, error handling and input validation is incomplete.

Extra features
--------------

In order to support patterns useful for and used in the Motoko test suite, the
IC stub has some extra features that are not spec’ed or implemented in the
official client. These are:

 * The ability to create calls from `canister_init`.

 * The ability to create additional canisters, in a way where the creating
   canisters learns the id of the created canister synchronously, and can send
   messages to it right away.

   The interface for that is

      ic.create_canister : (mod_src : i32, mod_size : i32, arg_src : i32, arg_size : i32) -> (idx : i32)
      ic.created_canister_id_size : (idx : i32) -> (size : i32)
      ic.created_canister_id_copy : (idx : i32, dst : i32, offset : i32, size : i32) -> ()

   where the `idx` is only valid within the same function invokation.

Installation of `ic-stub-run`
-----------------------------

If you use the top-level `nix-shell`, you should already have `ic-stub-run` in
your `PATH`.

To install it into your normal environment, run from the top-level repository
directory.


    nix-env -i -f . -A ic-stub


Developing on ic-stub
---------------------

Running `nix-shell` in the `ic-stub/` directory should give you an environment
that allows you to build the project using `cabal new-build`.

The interpreter is too slow
---------------------------

The obvious performance issue with `winter`, according to profiling, is
evaluation under lambdas, the cost centres `step_Label7_k`, `step_Label7`,
`step_Label2` and `step_Framed4` are responsible for most allocation. Switching
to an interpreter form with a control stack would likely help a lot, but would
move `winter` away from being a straight-forward port of the Ocaml reference
interpreter `wasm`.
