# HaSQLite: Building SQLite in Haskell

## Context

This is a greenfield educational project. The goal is to build a working SQLite implementation in Haskell — not for production use, but to deeply learn:
- **Functional programming**: ADTs, pattern matching, monads (IO, State, Reader, Except), monad transformers, property-based testing, binary serialization
- **Database internals**: B-trees, page-based storage, record formats, SQL parsing, bytecode compilation, virtual machines, transactions

The project directory `/Users/jay/lab/experiments/hasql` is currently empty.

### Architecture Overview (SQLite's pipeline)

```
SQL Text → Tokenizer → Parser → Code Generator → Virtual Machine → B-Tree → Pager → OS/File
           ─────────────────────────────────────   ───────────────────────────────────────────
                    SQL Compiler (Frontend)                    Storage Engine (Backend)
```

We build **bottom-up** (storage first, SQL last) so each layer has concrete, testable foundations beneath it.

---

## Phase 1: Project Setup & Foundation (Week 1)

**Learning focus**: Haskell tooling, project structure, binary I/O with `ByteString`

### 1.1 Project scaffolding
- Initialize with `cabal init` (library + executable + test-suite)
- Core dependencies: `bytestring`, `binary`, `megaparsec`, `text`, `vector`, `mtl`, `QuickCheck`, `hspec`
- Module layout:
  ```
  src/
    HaSQLite/
      Storage/
        Pager.hs        -- page I/O
        Varint.hs       -- SQLite varint encoding
        Record.hs       -- record format
        BTree.hs        -- B-tree operations
      Compiler/
        Lexer.hs        -- SQL tokenizer
        Parser.hs       -- SQL parser
        AST.hs          -- SQL abstract syntax tree
        CodeGen.hs      -- AST → bytecode
      VM/
        Types.hs        -- opcodes, registers, VM state
        Execute.hs      -- bytecode interpreter
      Core.hs           -- top-level API (prepare, step, finalize)
  app/
    Main.hs             -- REPL
  test/
    ...
  ```

### 1.2 Varint encoding/decoding
- Implement SQLite's varint format: 1-9 bytes, big-endian, 7 bits per byte with high-bit continuation
- Use `Data.Binary.Get` and `Data.Binary.Put` monads
- **FP concept**: `Get`/`Put` monads as domain-specific interpreters for binary serialization
- **Test**: QuickCheck round-trip property — `decode . encode ≡ id` for all `Int64` values

### 1.3 Page I/O (Pager)
- Fixed-size pages (4096 bytes default)
- Read/write individual pages by page number using `System.IO` + `hSeek`
- Database header (first 100 bytes of page 1): magic string, page size, page count
- **FP concept**: `IO` monad for file operations, `ReaderT` for config (page size)
- **DB concept**: Why pages? Disk I/O alignment, caching granularity

**Deliverable**: Can create a new database file, read/write raw pages, encode/decode varints.

---

## Phase 2: Record Format & B-Tree Reading (Weeks 2-3)

**Learning focus**: ADTs for data modeling, pattern matching, recursive data structures

### 2.1 Record serialization
- Define `SQLiteValue` ADT:
  ```haskell
  data SqlValue = SqlNull | SqlInt Int64 | SqlFloat Double | SqlText Text | SqlBlob ByteString
  ```
- Implement record format: header (serial types as varints) + body (values)
- Serial type mapping: 0=NULL, 1-6=ints, 7=float, 8=int 0, 9=int 1, >=12 even=blob, >=13 odd=text
- **FP concept**: ADTs with exhaustive pattern matching — the compiler enforces you handle every case
- **Test**: Round-trip property for arbitrary `[SqlValue]` lists

### 2.2 B-Tree page structure (read-only)
- Model B-tree page types as ADT:
  ```haskell
  data BTreePage
    = TableLeaf { cells :: [TableLeafCell] }
    | TableInterior { cells :: [TableInteriorCell], rightChild :: PageNum }
    | IndexLeaf { cells :: [IndexLeafCell] }
    | IndexInterior { cells :: [IndexInteriorCell], rightChild :: PageNum }
  ```
- Parse cell pointer array, read cells from page bytes
- Table leaf cell: payload size (varint) + rowid (varint) + record payload
- Table interior cell: child page (4 bytes) + rowid (varint)
- **FP concept**: Sum types to model disjoint page types; each variant carries exactly the data it needs
- **DB concept**: B-tree variants — table B-trees (integer key → data) vs index B-trees (arbitrary key → no data)

### 2.3 B-Tree traversal (read-only)
- Recursive tree traversal to scan all rows in a table
- Key lookup: binary search within page, recurse into child for interior nodes
- Range scans: in-order traversal
- **FP concept**: Recursion over tree structures, `IO` monad threading for page reads
- **Milestone test**: Create a small SQLite database with the real `sqlite3` CLI, then read it with HaSQLite — verify you get the same rows back

**Deliverable**: Can read tables from real SQLite database files.

---

## Phase 3: B-Tree Writing & Schema (Weeks 4-5)

**Learning focus**: `StateT` monad transformer, mutable state management in pure FP

### 3.1 B-Tree insertion
- Insert cell into leaf page (find correct position, shift cells)
- Page splitting when a leaf overflows: allocate new page, split cells, push median key up to parent
- Recursive splitting up through interior nodes
- Growing the tree: when root splits, create new root
- **FP concept**: `StateT` over `IO` — threading mutable database state (free page list, page cache) through pure-looking code
- **DB concept**: B-tree balancing, why splits maintain O(log n) height

### 3.2 B-Tree deletion
- Simple case: remove cell from leaf
- Underflow handling: borrow from sibling or merge pages
- **Test**: QuickCheck — insert N random keys, delete a subset, verify remaining keys are intact and tree invariants hold (sorted order, balanced height, page fill constraints)

### 3.3 Schema table (`sqlite_schema`)
- Page 1 is always the root of the `sqlite_schema` table
- Rows: `(type, name, tbl_name, rootpage, sql)`
- Parse CREATE TABLE statements to extract column names and types
- **DB concept**: Self-describing databases — the schema is stored in the database itself

**Deliverable**: Can create tables, insert rows, and persist them. Verified by reading back with real `sqlite3`.

---

## Phase 4: SQL Parser (Weeks 6-7)

**Learning focus**: Parser combinators, building ASTs, `Applicative`/`Monad` interplay

### 4.1 SQL AST definition
- Define types for the SQL subset you support:
  ```haskell
  data Statement
    = Select { columns :: [Expr], from :: TableName, whereClause :: Maybe Expr }
    | Insert { table :: TableName, columns :: [ColumnName], values :: [[Expr]] }
    | CreateTable { name :: TableName, columns :: [ColumnDef] }
    | Delete { table :: TableName, whereClause :: Maybe Expr }

  data Expr
    = LitInt Int64 | LitText Text | LitNull
    | ColRef ColumnName
    | BinOp Op Expr Expr
    | UnaryOp Op Expr
  ```
- **FP concept**: ADTs as the "universal interface" between compiler phases — each phase consumes one ADT and produces another

### 4.2 Lexer + Parser with Megaparsec
- Tokenize: keywords (`SELECT`, `FROM`, `WHERE`, `INSERT`, `CREATE`), identifiers, literals, operators, punctuation
- Parse with combinators: `select`, `insert`, `createTable` parsers composed from smaller pieces
- **FP concept**: Parser combinators — `<|>` (alternative), `<*>` (sequencing), `try` (backtracking). Parsers are values you compose, not grammar rules you declare
- **Test**: Parse → pretty-print → parse again, verify AST equality

### 4.3 Extend to cover:
- `UPDATE ... SET ... WHERE ...`
- `DELETE FROM ... WHERE ...`
- Comparison operators: `=`, `<>`, `<`, `>`, `<=`, `>=`
- Logical operators: `AND`, `OR`, `NOT`
- `ORDER BY`, `LIMIT`

**Deliverable**: Can parse a useful subset of SQL into a typed AST.

---

## Phase 5: Virtual Machine (Weeks 8-9)

**Learning focus**: Interpreter design, register machines, the `ST` monad for local mutability

### 5.1 VM types and opcodes
- Define opcodes as ADT:
  ```haskell
  data OpCode
    = Init | Goto | Halt
    | OpenRead | OpenWrite | Close
    | Rewind | Next | Column | ResultRow
    | SeekGE | SeekLE
    | Integer | String
    | Eq | Ne | Lt | Le | Gt | Ge
    | MakeRecord | Insert | Delete
    | CreateTable
    | ...
  ```
- Instruction: `data Instruction = Instruction { opcode :: OpCode, p1 :: Int, p2 :: Int, p3 :: Int, p4 :: Maybe P4Value }`
- VM state: program counter, registers (as `Vector`), open cursors (B-tree iterators), result accumulator
- **FP concept**: ADTs for opcodes give exhaustive checking — add a new opcode and the compiler tells you every place that needs updating

### 5.2 Bytecode interpreter
- Tight recursive loop with pattern matching on opcodes
- Each opcode handler: read operands → perform action → advance PC (or jump)
- Cursor abstraction over B-tree: `cursorRewind`, `cursorNext`, `cursorColumn`, `cursorEof`
- **FP concept**: `StateT VMState IO` monad — the VM loop is pure state threading with IO only at B-tree boundaries
- **DB concept**: Why bytecode? Decouples "what to execute" from "how to execute it" — enables `EXPLAIN` for free

### 5.3 EXPLAIN support
- Pretty-print bytecode programs (opcode table like real SQLite's `EXPLAIN`)
- Invaluable for debugging the code generator in Phase 6

**Deliverable**: Can manually construct bytecode programs and execute them against the B-tree storage layer.

---

## Phase 6: Code Generator & Integration (Weeks 10-12)

**Learning focus**: Compiling high-level representations to low-level ones, full system integration

### 6.1 Code generator
- Walk the SQL AST, emit bytecode instructions:
  - `SELECT`: OpenRead → Rewind → [loop: Column, ResultRow, Next] → Close → Halt
  - `INSERT`: OpenWrite → MakeRecord → Insert → Close → Halt
  - `CREATE TABLE`: CreateTable → insert into sqlite_schema → Halt
  - `WHERE` clauses: emit comparison + conditional jump opcodes
- **FP concept**: Tree-walking compiler as a pure function `Statement -> [Instruction]` — no side effects in compilation
- **DB concept**: Query compilation — the same SQL can produce different bytecode depending on available indexes

### 6.2 REPL
- Read-eval-print loop: read SQL → parse → compile → execute → display results
- Handle `.tables`, `.schema`, `.quit` dot-commands
- Display results as formatted ASCII tables
- **FP concept**: The REPL is a small interpreter loop itself — `forever (readLine >>= parse >>= compile >>= execute >>= display)`

### 6.3 End-to-end integration
- Wire everything together: `Core.prepare` (parse + compile), `Core.step` (VM step), `Core.finalize` (cleanup)
- Monad stack: `ReaderT Config (StateT DBState (ExceptT HaSQLiteError IO))`
- **Test**: Create database with HaSQLite, read with real `sqlite3`, and vice versa

**Deliverable**: Working SQLite-compatible REPL that can CREATE TABLE, INSERT, SELECT, DELETE.

---

## Phase 7: Advanced Topics (Ongoing)

Pick based on interest — each is independently valuable:

| Topic | FP Concepts | DB Concepts |
|-------|-------------|-------------|
| **Transactions & WAL** | Bracket pattern for resource safety, `MonadMask` | ACID, write-ahead logging, crash recovery |
| **Indexes** | More ADT variants, generalized B-tree | Secondary indexes, covering indexes, query planning |
| **Joins** | Lazy evaluation for nested-loop joins | Join algorithms (nested loop, sort-merge, hash) |
| **Aggregates** | Folds and accumulators | GROUP BY, HAVING, aggregate functions |
| **Page cache** | `IORef`/`MVar` for mutable cache, LRU eviction | Buffer pool management, cache hit rates |
| **Concurrent reads** | `MVar`/`STM` for reader-writer locks | MVCC, isolation levels |
| **Property testing** | `quickcheck-state-machine` | Model-based testing: verify HaSQLite matches a `Map`-based reference |

---

## Key Haskell Libraries

| Library | Purpose | Phase |
|---------|---------|-------|
| `bytestring` | Binary data, page buffers | 1+ |
| `binary` | `Get`/`Put` monads for serialization | 1+ |
| `megaparsec` | SQL parser combinators | 4 |
| `text` | Text handling for SQL strings | 1+ |
| `vector` | VM registers, efficient arrays | 5 |
| `mtl` | Monad transformers (ReaderT, StateT, ExceptT) | 3+ |
| `QuickCheck` | Property-based testing | 1+ |
| `hspec` | Test framework | 1+ |

## Verification Strategy

At each phase boundary:
1. **Unit tests**: QuickCheck properties + hspec examples for each module
2. **Integration tests**: Round-trip with real `sqlite3` CLI starting from Phase 2
3. **EXPLAIN**: From Phase 5 onward, use `EXPLAIN` output to verify compiled bytecode
4. **Compatibility check**: Create DB with HaSQLite → read with `sqlite3`, and vice versa
