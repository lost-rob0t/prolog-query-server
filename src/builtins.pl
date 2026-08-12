:- module(builtins,
          [ builtin_goal/1,
            builtin_name/1,
            execute_builtin/1,
            builtin_catalog/1
          ]).

:- use_module(library(error)).

builtin_spec(eq, 2, "unification").
builtin_spec(neq, 2, "unification").
builtin_spec(calc, 2, "arithmetic").
builtin_spec(lt, 2, "comparison").
builtin_spec(lte, 2, "comparison").
builtin_spec(gt, 2, "comparison").
builtin_spec(gte, 2, "comparison").
builtin_spec(is_number, 1, "type").
builtin_spec(is_string, 1, "type").
builtin_spec(is_atom, 1, "type").
builtin_spec(is_list, 1, "type").
builtin_spec(is_compound, 1, "type").
builtin_spec(is_ground, 1, "type").

arithmetic_spec(add, 2).
arithmetic_spec(sub, 2).
arithmetic_spec(mul, 2).
arithmetic_spec(div, 2).
arithmetic_spec(mod, 2).
arithmetic_spec(abs, 1).
arithmetic_spec(min, 2).
arithmetic_spec(max, 2).

builtin_name(Predicate) :-
    builtin_spec(Predicate, _Arity, _Category).

builtin_goal(goal(Predicate, Args)) :-
    builtin_spec(Predicate, Arity, _Category),
    !,
    length(Args, ActualArity),
    (   ActualArity =:= Arity
    ->  true
    ;   throw(error(domain_error(builtin_arity(Predicate, Arity), ActualArity), _))
    ).

execute_builtin(goal(eq, [Left, Right])) :-
    Left = Right.
execute_builtin(goal(neq, [Left, Right])) :-
    dif(Left, Right).
execute_builtin(goal(calc, [Result, Expression])) :-
    eval_numeric(Expression, Value),
    Result = Value.
execute_builtin(goal(lt, [Left, Right])) :-
    numeric_pair(Left, Right, A, B),
    A < B.
execute_builtin(goal(lte, [Left, Right])) :-
    numeric_pair(Left, Right, A, B),
    A =< B.
execute_builtin(goal(gt, [Left, Right])) :-
    numeric_pair(Left, Right, A, B),
    A > B.
execute_builtin(goal(gte, [Left, Right])) :-
    numeric_pair(Left, Right, A, B),
    A >= B.
execute_builtin(goal(is_number, [Value])) :-
    number(Value).
execute_builtin(goal(is_string, [Value])) :-
    string(Value).
execute_builtin(goal(is_atom, [Value])) :-
    atom(Value).
execute_builtin(goal(is_list, [Value])) :-
    is_list(Value).
execute_builtin(goal(is_compound, [Value])) :-
    compound(Value).
execute_builtin(goal(is_ground, [Value])) :-
    ground(Value).

builtin_catalog(Catalog) :-
    findall(_{name:NameString, arity:Arity, category:Category},
            ( builtin_spec(Name, Arity, Category),
              atom_string(Name, NameString)
            ),
            Builtins),
    findall(_{op:OpString, arity:Arity},
            ( arithmetic_spec(Op, Arity),
              atom_string(Op, OpString)
            ),
            Arithmetic),
    Catalog = _{builtins:Builtins, arithmetic_operators:Arithmetic}.

numeric_pair(Left, Right, A, B) :-
    eval_numeric(Left, A),
    eval_numeric(Right, B).

eval_numeric(Value, Value) :-
    number(Value),
    !.
eval_numeric(Expression, Result) :-
    compound(Expression),
    Expression =.. [Op|Args],
    arithmetic_spec(Op, Arity),
    !,
    length(Args, ActualArity),
    (   ActualArity =:= Arity
    ->  maplist(eval_numeric, Args, Values),
        apply_arithmetic(Op, Values, Result)
    ;   throw(error(domain_error(arithmetic_arity(Op, Arity), ActualArity), _))
    ).
eval_numeric(Value, _) :-
    var(Value),
    !,
    throw(error(instantiation_error, _)).
eval_numeric(Value, _) :-
    throw(error(type_error(numeric_expression, Value), _)).

apply_arithmetic(add, [A, B], Result) :-
    Result is A + B.
apply_arithmetic(sub, [A, B], Result) :-
    Result is A - B.
apply_arithmetic(mul, [A, B], Result) :-
    Result is A * B.
apply_arithmetic(div, [A, B], Result) :-
    nonzero(B),
    Result is A / B.
apply_arithmetic(mod, [A, B], Result) :-
    must_be(integer, A),
    must_be(integer, B),
    nonzero(B),
    Result is A mod B.
apply_arithmetic(abs, [A], Result) :-
    Result is abs(A).
apply_arithmetic(min, [A, B], Result) :-
    Result is min(A, B).
apply_arithmetic(max, [A, B], Result) :-
    Result is max(A, B).

nonzero(Value) :-
    (   Value =:= 0
    ->  throw(error(evaluation_error(zero_divisor), _))
    ;   true
    ).
