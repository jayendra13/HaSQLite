# HaSQLite

SQLite implementation in Haskell — educational project for learning FP and database internals.

## Build & Test

```bash
cabal build all    # build library, executable, and tests
cabal test         # run test suite
cabal run hasqlite # run the executable
```

## Project Structure

```
src/HaSQLite/
  Storage/       -- storage engine (pager, B-tree, varint, record format)
  Compiler/      -- SQL frontend (lexer, parser, AST, codegen)
  VM/            -- bytecode virtual machine
  Core.hs        -- top-level API
app/Main.hs      -- REPL entry point
test/Main.hs     -- test suite (hspec + QuickCheck)
```

## Conventions

- Git commits must NOT include `Co-Authored-By` lines.
- Tests use hspec for unit tests and QuickCheck for property-based tests.
- Module namespace is `HaSQLite`.
