:- begin_tests(builtins).

:- use_module('../src/builtins').
:- use_module('../src/expert_system').

fact(Id, Predicate, Args, Doc) :-
    Doc = _{'_id':Id,
            type:"prolog_fact",
            kb:"builtins",
            enabled:true,
            predicate:Predicate,
            args:Args}.

rule(Id, Head, Body, Doc) :-
    Doc = _{'_id':Id,
            type:"prolog_rule",
            kb:"builtins",
            enabled:true,
            head:Head,
            body:Body}.

test(catalog_exposes_registry) :-
    builtin_catalog(Catalog),
    get_dict(builtins, Catalog, Specs),
    member(_{name:"calc", arity:2, category:"arithmetic"}, Specs),
    member(_{name:"gte", arity:2, category:"comparison"}, Specs),
    get_dict(arithmetic_operators, Catalog, Ops),
    member(_{op:"add", arity:2}, Ops),
    member(_{op:"abs", arity:1}, Ops).

test(arithmetic_and_comparison_rule) :-
    fact("score:alice", "score", ["alice", 72], Score),
    rule("rule:qualified",
         _{predicate:"qualified", args:[_{var:"X"}, _{var:"Adjusted"}]},
         [ _{predicate:"score", args:[_{var:"X"}, _{var:"S"}]},
           _{predicate:"is_number", args:[_{var:"S"}]},
           _{predicate:"calc",
             args:[_{var:"Adjusted"},
                   _{functor:"add", args:[_{var:"S"}, 10]}]},
           _{predicate:"gte", args:[_{var:"Adjusted"}, 80]},
           _{predicate:"lt", args:[_{var:"Adjusted"}, 100]}
         ],
         Qualified),
    replace_kb("builtins", [Score, Qualified], _),
    run_query("builtins",
              _{predicate:"qualified", args:[_{var:"Who"}, _{var:"Adjusted"}]},
              [trace(true)],
              Result),
    get_dict(solutions, Result, [Solution]),
    get_dict(bindings, Solution, Bindings),
    get_dict('Who', Bindings, "alice"),
    get_dict('Adjusted', Bindings, 82),
    get_dict(proof, Solution, Proof),
    get_dict(children, Proof, Children),
    findall(P,
            (member(C, Children), get_dict(kind, C, "builtin"), get_dict(predicate, C, P)),
            BuiltinPredicates),
    BuiltinPredicates == ["is_number", "calc", "gte", "lt"].

test(all_arithmetic_operators) :-
    replace_kb("builtins-arith", [], _),
    arithmetic_result("builtins-arith", add, [2, 3], 5),
    arithmetic_result("builtins-arith", sub, [9, 4], 5),
    arithmetic_result("builtins-arith", mul, [3, 7], 21),
    arithmetic_result("builtins-arith", div, [9, 2], 4.5),
    arithmetic_result("builtins-arith", mod, [10, 3], 1),
    arithmetic_result("builtins-arith", abs, [-7], 7),
    arithmetic_result("builtins-arith", min, [7, 3], 3),
    arithmetic_result("builtins-arith", max, [7, 3], 7).

test(nested_numeric_expression) :-
    replace_kb("builtins-nested", [], _),
    run_query("builtins-nested",
              _{predicate:"calc",
                args:[_{var:"Result"},
                      _{functor:"mul",
                        args:[_{functor:"add", args:[2, 3]},
                              _{functor:"sub", args:[10, 6]}]}]},
              [],
              Result),
    get_dict(solutions, Result, [Solution]),
    get_dict(bindings, Solution, Bindings),
    get_dict('Result', Bindings, 20).

test(type_predicates) :-
    replace_kb("builtins-types", [], _),
    builtin_succeeds("builtins-types", _{predicate:"is_number", args:[42]}),
    builtin_succeeds("builtins-types", _{predicate:"is_string", args:["hello"]}),
    builtin_succeeds("builtins-types", _{predicate:"is_atom", args:[_{atom:"hello"}]}),
    builtin_succeeds("builtins-types", _{predicate:"is_list", args:[[1,2,3]]}),
    builtin_succeeds("builtins-types", _{predicate:"is_compound", args:[_{functor:"point",args:[1,2]}]}),
    builtin_succeeds("builtins-types", _{predicate:"is_ground", args:[_{functor:"point",args:[1,2]}]}).

test(comparison_failure_is_no_solution) :-
    replace_kb("builtins-compare", [], _),
    run_query("builtins-compare", _{predicate:"gt", args:[2, 10]}, [], Result),
    get_dict(count, Result, 0).

test(divide_by_zero_rejected,
     [throws(error(evaluation_error(zero_divisor), _))]) :-
    replace_kb("builtins-zero", [], _),
    run_query("builtins-zero",
              _{predicate:"calc",
                args:[_{var:"R"}, _{functor:"div", args:[1,0]}]},
              [], _).

test(unknown_arithmetic_functor_is_data_not_execution,
     [throws(error(type_error(numeric_expression, shell("id")), _))]) :-
    replace_kb("builtins-unsafe", [], _),
    run_query("builtins-unsafe",
              _{predicate:"calc",
                args:[_{var:"R"}, _{functor:"shell", args:["id"]}]},
              [], _).

test(cannot_define_builtin_fact,
     [throws(error(permission_error(define, builtin_predicate, calc), _))]) :-
    Bad = _{type:"prolog_fact", kb:"builtins", predicate:"calc", args:[1,2]},
    validate_document(Bad).

test(cannot_define_builtin_rule,
     [throws(error(permission_error(define, builtin_predicate, gte), _))]) :-
    Bad = _{type:"prolog_rule",
            kb:"builtins",
            head:_{predicate:"gte", args:[1,2]},
            body:[]},
    validate_document(Bad).

test(wrong_builtin_arity_rejected,
     [throws(error(domain_error(builtin_arity(calc, 2), 1), _))]) :-
    replace_kb("builtins-arity", [], _),
    run_query("builtins-arity", _{predicate:"calc", args:[1]}, [], _).

arithmetic_result(KB, Op, Args, Expected) :-
    Expression = _{functor:Op, args:Args},
    run_query(KB,
              _{predicate:"calc", args:[_{var:"Result"}, Expression]},
              [],
              Result),
    get_dict(solutions, Result, [Solution]),
    get_dict(bindings, Solution, Bindings),
    get_dict('Result', Bindings, Expected).

builtin_succeeds(KB, Goal) :-
    run_query(KB, Goal, [], Result),
    get_dict(count, Result, 1).

:- end_tests(builtins).
