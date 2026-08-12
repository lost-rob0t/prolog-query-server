# Safe expert-system builtins

Stored rules can invoke a small whitelist of deterministic builtins. Persisted knowledge never reaches arbitrary Prolog `call/1`.

Inspect the registry with:

```bash
curl -sS http://localhost:8080/v1/builtins
```

## Predicates

- `eq(A,B)`, `neq(A,B)` — unification/disequality
- `calc(Result, Expression)` — evaluate a whitelisted numeric expression
- `lt(A,B)`, `lte(A,B)`, `gt(A,B)`, `gte(A,B)` — numeric comparisons; each operand may be a numeric expression
- `is_number(X)`, `is_string(X)`, `is_atom(X)`, `is_list(X)`, `is_compound(X)`, `is_ground(X)` — safe type/shape tests

Builtin names are reserved and cannot be defined as persisted fact or rule heads.

## Arithmetic expression AST

Arithmetic uses the existing compound-term JSON representation:

```json
{"functor":"add","args":[{"var":"Score"},10]}
```

Allowed operators are `add/2`, `sub/2`, `mul/2`, `div/2`, `mod/2`, `abs/1`, `min/2`, and `max/2`.

Example rule fragment:

```json
[
  {"predicate":"calc","args":[{"var":"Adjusted"},{"functor":"add","args":[{"var":"Score"},10]}]},
  {"predicate":"gte","args":[{"var":"Adjusted"},80]}
]
```

Unknown functors are never executed. For example, `{"functor":"shell","args":["id"]}` passed to `calc` is rejected as a non-numeric expression.

Division/modulo by zero and malformed numeric expressions return a query error rather than silently failing. `mod` requires integer operands.

## Proofs

Every successful builtin used by an explained query appears as a `kind: "builtin"` proof node with its predicate, resolved goal values, and `decision: "succeeded"`.
