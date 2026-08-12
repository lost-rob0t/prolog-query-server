:- module(query_server_protocol,
          [ reset_state/0,
            handle_command/2
          ]).

:- use_module(library(error)).
:- use_module(library(lists)).

:- dynamic map_function/2.
:- dynamic design_document/2.
:- dynamic query_library/1.

reset_state :-
    retractall(map_function(_, _)),
    retractall(design_document(_, _)),
    retractall(query_library(_)).

handle_command(["reset"|_], true) :-
    !,
    reset_state.
handle_command(["add_lib", Library], true) :-
    !,
    assertz(query_library(Library)).
handle_command(["add_fun", Source], true) :-
    !,
    parse_map_source(Source, AST),
    next_map_index(Index),
    assertz(map_function(Index, AST)).
handle_command(["map_doc", Document], Results) :-
    !,
    must_be(dict, Document),
    findall(Index-AST, map_function(Index, AST), Functions),
    maplist(run_map(Document), Functions, Results).
% CouchDB 3.5 appends an opaque context value to reduce/rereduce requests.
% Keep the documented three-argument form too for compatibility with older
% CouchDB releases and direct protocol clients.
handle_command(["reduce", Sources, Rows], Reply) :-
    !,
    reduce_command(Sources, Rows, Reply).
handle_command(["reduce", Sources, Rows, _Context], Reply) :-
    !,
    reduce_command(Sources, Rows, Reply).
handle_command(["rereduce", Sources, Values], Reply) :-
    !,
    rereduce_command(Sources, Values, Reply).
handle_command(["rereduce", Sources, Values, _Context], Reply) :-
    !,
    rereduce_command(Sources, Values, Reply).
handle_command(["ddoc", "new", Id, Document], true) :-
    !,
    must_be(dict, Document),
    retractall(design_document(Id, _)),
    assertz(design_document(Id, Document)).
handle_command(["ddoc", Id, Path, _Args], _Reply) :-
    !,
    (   design_document(Id, _)
    ->  true
    ;   throw(error(existence_error(design_document, Id), _))
    ),
    throw(error(permission_error(execute, unsupported_ddoc_function, Path), _)).
handle_command([Command|_], _Reply) :-
    throw(error(domain_error(query_server_command, Command), _)).
handle_command(Message, _Reply) :-
    throw(error(type_error(query_server_message, Message), _)).

reduce_command(Sources, Rows, [true, Results]) :-
    must_be(list, Sources),
    must_be(list, Rows),
    maplist(reduce_source(Rows, false), Sources, Results).

rereduce_command(Sources, Values, [true, Results]) :-
    must_be(list, Sources),
    must_be(list, Values),
    maplist(reduce_source(Values, true), Sources, Results).

next_map_index(Index) :-
    findall(I, map_function(I, _), Existing),
    (   Existing == []
    ->  Index = 1
    ;   max_list(Existing, Max),
        Index is Max + 1
    ).

parse_map_source(Source, AST) :-
    text_atom(Source, Atom),
    read_term_from_atom(Atom,
                        AST,
                        [ syntax_errors(error),
                          variable_names(Variables)
                        ]),
    (   Variables == []
    ->  true
    ;   throw(error(domain_error(ground_map_dsl, Source), _))
    ),
    validate_action(AST).

run_map(Document, _Index-AST, Emissions) :-
    findall([Key, Value], eval_action(AST, Document, Key, Value), Emissions).

validate_action(emit(Key, Value)) :-
    !,
    validate_expr(Key),
    validate_expr(Value).
validate_action(where(Condition, Action)) :-
    !,
    validate_condition(Condition),
    validate_action(Action).
validate_action(all(Actions)) :-
    !,
    must_be(list, Actions),
    maplist(validate_action, Actions).
validate_action(Term) :-
    throw(error(domain_error(map_dsl_action, Term), _)).

validate_condition(true) :- !.
validate_condition(false) :- !.
validate_condition(exists(Expr)) :- !, validate_expr(Expr).
validate_condition(eq(Left, Right)) :- !, validate_expr(Left), validate_expr(Right).
validate_condition(neq(Left, Right)) :- !, validate_expr(Left), validate_expr(Right).
validate_condition(gt(Left, Right)) :- !, validate_expr(Left), validate_expr(Right).
validate_condition(gte(Left, Right)) :- !, validate_expr(Left), validate_expr(Right).
validate_condition(lt(Left, Right)) :- !, validate_expr(Left), validate_expr(Right).
validate_condition(lte(Left, Right)) :- !, validate_expr(Left), validate_expr(Right).
validate_condition(and(Conditions)) :- !, must_be(list, Conditions), maplist(validate_condition, Conditions).
validate_condition(or(Conditions)) :- !, must_be(list, Conditions), maplist(validate_condition, Conditions).
validate_condition(not(Condition)) :- !, validate_condition(Condition).
validate_condition(Term) :-
    throw(error(domain_error(map_dsl_condition, Term), _)).

validate_expr(field(Path)) :- !, validate_path(Path).
validate_expr(object(Pairs)) :- !, must_be(list, Pairs), maplist(validate_object_pair, Pairs).
validate_expr(array(Values)) :- !, must_be(list, Values), maplist(validate_expr, Values).
validate_expr(Value) :-
    json_scalar(Value),
    !.
validate_expr(Term) :-
    throw(error(domain_error(map_dsl_expression, Term), _)).

validate_object_pair(Key-Expr) :-
    text_atom(Key, _),
    validate_expr(Expr).

validate_path(Path) :-
    (   is_list(Path)
    ->  Path \== [], maplist(path_key, Path)
    ;   path_key(Path)
    ).

path_key(Key) :-
    text_atom(Key, _).

json_scalar(Value) :-
    string(Value), !.
json_scalar(Value) :-
    number(Value), !.
json_scalar(true).
json_scalar(false).
json_scalar(null).

:- discontiguous eval_action/4.

eval_action(emit(KeyExpr, ValueExpr), Document, Key, Value) :-
    eval_expr(KeyExpr, Document, Key),
    eval_expr(ValueExpr, Document, Value).
eval_action(where(Condition, Action), Document, Key, Value) :-
    eval_condition(Condition, Document),
    eval_action(Action, Document, Key, Value).
eval_action(all(Actions), Document, Key, Value) :-
    member(Action, Actions),
    eval_action(Action, Document, Key, Value).

eval_condition(true, _Document) :- !.
eval_condition(false, _Document) :- !, fail.
eval_condition(exists(Expr), Document) :- !, eval_expr(Expr, Document, _).
eval_condition(eq(Left, Right), Document) :- !,
    eval_expr(Left, Document, LeftValue),
    eval_expr(Right, Document, RightValue),
    LeftValue == RightValue.
eval_condition(neq(Left, Right), Document) :- !,
    eval_expr(Left, Document, LeftValue),
    eval_expr(Right, Document, RightValue),
    LeftValue \== RightValue.
eval_condition(gt(Left, Right), Document) :- !,
    numeric_values(Left, Right, Document, A, B),
    A > B.
eval_condition(gte(Left, Right), Document) :- !,
    numeric_values(Left, Right, Document, A, B),
    A >= B.
eval_condition(lt(Left, Right), Document) :- !,
    numeric_values(Left, Right, Document, A, B),
    A < B.
eval_condition(lte(Left, Right), Document) :- !,
    numeric_values(Left, Right, Document, A, B),
    A =< B.
eval_condition(and(Conditions), Document) :- !,
    maplist(condition_on(Document), Conditions).
eval_condition(or(Conditions), Document) :- !,
    member(Condition, Conditions),
    eval_condition(Condition, Document),
    !.
eval_condition(not(Condition), Document) :-
    \+ eval_condition(Condition, Document).

condition_on(Document, Condition) :-
    eval_condition(Condition, Document).

numeric_values(Left, Right, Document, A, B) :-
    eval_expr(Left, Document, A),
    eval_expr(Right, Document, B),
    number(A),
    number(B).

eval_expr(field(Path), Document, Value) :-
    !,
    normalize_path(Path, Keys),
    field_path(Keys, Document, Value).
eval_expr(object(Pairs), Document, Dict) :-
    !,
    maplist(eval_object_pair(Document), Pairs, Evaluated),
    dict_create(Dict, json, Evaluated).
eval_expr(array(Values), Document, Evaluated) :-
    !,
    maplist(expr_on(Document), Values, Evaluated).
eval_expr(Value, _Document, Value) :-
    json_scalar(Value).

expr_on(Document, Expr, Value) :-
    eval_expr(Expr, Document, Value).

eval_object_pair(Document, Key0-Expr, Key-Value) :-
    text_atom(Key0, Key),
    eval_expr(Expr, Document, Value).

normalize_path(Path, Keys) :-
    (   is_list(Path)
    ->  maplist(text_atom, Path, Keys)
    ;   text_atom(Path, Key),
        Keys = [Key]
    ).

field_path([Key], Dict, Value) :-
    get_dict(Key, Dict, Value).
field_path([Key|Rest], Dict, Value) :-
    Rest \== [],
    get_dict(Key, Dict, Next),
    is_dict(Next),
    field_path(Rest, Next, Value).

reduce_source(RowsOrValues, ReReduce, Source, Result) :-
    parse_reduce_source(Source, Reducer),
    reduce_values(RowsOrValues, ReReduce, Reducer, Result).

parse_reduce_source(Source, Reducer) :-
    text_atom(Source, Atom),
    read_term_from_atom(Atom, Reducer, [syntax_errors(error)]),
    (   memberchk(Reducer, [sum, count, min, max, stats])
    ->  true
    ;   throw(error(domain_error(reduce_dsl, Reducer), _))
    ).

reduce_values(Input, false, Reducer, Result) :-
    maplist(row_value, Input, Values),
    apply_reducer(Reducer, Values, false, Result).
reduce_values(Values, true, Reducer, Result) :-
    apply_reducer(Reducer, Values, true, Result).

row_value([_KeyAndId, Value], Value) :- !.
row_value(Row, _) :-
    throw(error(domain_error(reduce_row, Row), _)).

apply_reducer(sum, Values, _ReReduce, Result) :-
    maplist(must_be(number), Values),
    sum_list(Values, Result).
apply_reducer(count, Values, false, Result) :-
    length(Values, Result).
apply_reducer(count, Values, true, Result) :-
    maplist(must_be(number), Values),
    sum_list(Values, Result).
apply_reducer(min, [First|Rest], _ReReduce, Result) :-
    foldl(min_value, Rest, First, Result).
apply_reducer(max, [First|Rest], _ReReduce, Result) :-
    foldl(max_value, Rest, First, Result).
apply_reducer(stats, Values, false, Result) :-
    maplist(must_be(number), Values),
    numeric_stats(Values, Result).
apply_reducer(stats, Stats, true, Result) :-
    combine_stats(Stats, Result).

min_value(Value, Acc, Min) :-
    ( Value @< Acc -> Min = Value ; Min = Acc ).
max_value(Value, Acc, Max) :-
    ( Value @> Acc -> Max = Value ; Max = Acc ).

numeric_stats([], _{sum:0, count:0, min:null, max:null, sumsqr:0}).
numeric_stats([First|Rest], Stats) :-
    FirstSqr is First*First,
    foldl(stats_step,
          Rest,
          state(First, 1, First, First, FirstSqr),
          state(Sum, Count, Min, Max, SumSqr)),
    Stats = _{sum:Sum, count:Count, min:Min, max:Max, sumsqr:SumSqr}.

stats_step(Value,
           state(Sum0, Count0, Min0, Max0, SumSqr0),
           state(Sum, Count, Min, Max, SumSqr)) :-
    Sum is Sum0 + Value,
    Count is Count0 + 1,
    Min is min(Min0, Value),
    Max is max(Max0, Value),
    SumSqr is SumSqr0 + Value*Value.

combine_stats([], _{sum:0, count:0, min:null, max:null, sumsqr:0}).
combine_stats([First|Rest], Result) :-
    must_be(dict, First),
    foldl(combine_stats_step, Rest, First, Result).

combine_stats_step(Next, Acc0, Acc) :-
    must_be(dict, Next),
    get_dict(sum, Acc0, Sum0),
    get_dict(sum, Next, NextSum),
    get_dict(count, Acc0, Count0),
    get_dict(count, Next, NextCount),
    get_dict(sumsqr, Acc0, SumSqr0),
    get_dict(sumsqr, Next, NextSumSqr),
    get_dict(min, Acc0, Min0),
    get_dict(min, Next, NextMin),
    get_dict(max, Acc0, Max0),
    get_dict(max, Next, NextMax),
    Sum is Sum0 + NextSum,
    Count is Count0 + NextCount,
    SumSqr is SumSqr0 + NextSumSqr,
    combine_optional_min(Min0, NextMin, Min),
    combine_optional_max(Max0, NextMax, Max),
    Acc = _{sum:Sum, count:Count, min:Min, max:Max, sumsqr:SumSqr}.

combine_optional_min(null, Value, Value) :- !.
combine_optional_min(Value, null, Value) :- !.
combine_optional_min(A, B, Min) :- Min is min(A, B).
combine_optional_max(null, Value, Value) :- !.
combine_optional_max(Value, null, Value) :- !.
combine_optional_max(A, B, Max) :- Max is max(A, B).

text_atom(Value, Atom) :-
    (   atom(Value)
    ->  Atom = Value
    ;   string(Value)
    ->  atom_string(Atom, Value)
    ;   throw(error(type_error(text, Value), _))
    ).
