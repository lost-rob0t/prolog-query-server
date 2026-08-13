:- module(query_server_protocol,
          [ reset_state/0,
            handle_command/2
          ]).

:- use_module(library(date)).
:- use_module(library(error)).
:- use_module(library(lists)).
:- use_module(library(solution_sequences)).

:- dynamic map_function/2.
:- dynamic design_document/2.
:- dynamic query_library/1.

max_iterator_depth(4).
max_collection_items(4096).
max_map_emissions(4096).
max_text_codepoints(65536).
max_tokens(4096).

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
    validate_action(AST, 0).

run_map(Document, _Index-AST, Emissions) :-
    max_map_emissions(Max),
    Limit is Max + 1,
    findnsols(Limit,
              [Key, Value],
              eval_action(AST, Document, [], Key, Value),
              CandidateEmissions),
    length(CandidateEmissions, Count),
    (   Count =< Max
    ->  Emissions = CandidateEmissions
    ;   throw(error(resource_error(max_map_emissions), _))
    ).

validate_action(emit(Key, Value), Depth) :-
    !,
    validate_expr(Key, Depth),
    validate_expr(Value, Depth).
validate_action(where(Condition, Action), Depth) :-
    !,
    validate_condition(Condition, Depth),
    validate_action(Action, Depth).
validate_action(all(Actions), Depth) :-
    !,
    must_be(list, Actions),
    maplist(validate_action_at_depth(Depth), Actions).
validate_action(for_each(CollectionExpr, Action), Depth) :-
    !,
    validate_expr(CollectionExpr, Depth),
    max_iterator_depth(MaxDepth),
    (   Depth < MaxDepth
    ->  NextDepth is Depth + 1,
        validate_action(Action, NextDepth)
    ;   throw(error(resource_error(max_iterator_depth), _))
    ).
validate_action(Term, _Depth) :-
    throw(error(domain_error(map_dsl_action, Term), _)).

validate_action_at_depth(Depth, Action) :-
    validate_action(Action, Depth).

validate_condition(true, _Depth) :- !.
validate_condition(false, _Depth) :- !.
validate_condition(exists(Expr), Depth) :- !, validate_expr(Expr, Depth).
validate_condition(eq(Left, Right), Depth) :- !, validate_expr(Left, Depth), validate_expr(Right, Depth).
validate_condition(neq(Left, Right), Depth) :- !, validate_expr(Left, Depth), validate_expr(Right, Depth).
validate_condition(gt(Left, Right), Depth) :- !, validate_expr(Left, Depth), validate_expr(Right, Depth).
validate_condition(gte(Left, Right), Depth) :- !, validate_expr(Left, Depth), validate_expr(Right, Depth).
validate_condition(lt(Left, Right), Depth) :- !, validate_expr(Left, Depth), validate_expr(Right, Depth).
validate_condition(lte(Left, Right), Depth) :- !, validate_expr(Left, Depth), validate_expr(Right, Depth).
validate_condition(and(Conditions), Depth) :- !,
    must_be(list, Conditions),
    maplist(validate_condition_at_depth(Depth), Conditions).
validate_condition(or(Conditions), Depth) :- !,
    must_be(list, Conditions),
    maplist(validate_condition_at_depth(Depth), Conditions).
validate_condition(not(Condition), Depth) :- !, validate_condition(Condition, Depth).
validate_condition(Term, _Depth) :-
    throw(error(domain_error(map_dsl_condition, Term), _)).

validate_condition_at_depth(Depth, Condition) :-
    validate_condition(Condition, Depth).

validate_expr(field(Path), _Depth) :- !, validate_path(Path).
validate_expr(object(Pairs), Depth) :- !,
    must_be(list, Pairs),
    maplist(validate_object_pair_at_depth(Depth), Pairs).
validate_expr(array(Values), Depth) :- !,
    must_be(list, Values),
    maplist(validate_expr_at_depth(Depth), Values).
validate_expr(normalize_text(Expr), Depth) :- !, validate_expr(Expr, Depth).
validate_expr(lower(Expr), Depth) :- !, validate_expr(Expr, Depth).
validate_expr(tokens(Expr), Depth) :- !, validate_expr(Expr, Depth).
validate_expr(time_part(Unit, Expr), Depth) :-
    !,
    validate_time_unit(Unit),
    validate_expr(Expr, Depth).
validate_expr(item, Depth) :-
    !,
    require_iterator_scope(Depth, item).
validate_expr(item(Path), Depth) :-
    !,
    require_iterator_scope(Depth, item(Path)),
    validate_path(Path).
validate_expr(Value, _Depth) :-
    json_scalar(Value),
    !.
validate_expr(Term, _Depth) :-
    throw(error(domain_error(map_dsl_expression, Term), _)).

validate_expr_at_depth(Depth, Expr) :-
    validate_expr(Expr, Depth).

validate_object_pair_at_depth(Depth, Key-Expr) :-
    text_atom(Key, _),
    validate_expr(Expr, Depth).

require_iterator_scope(Depth, _Term) :-
    Depth > 0,
    !.
require_iterator_scope(_Depth, Term) :-
    throw(error(permission_error(use, iterator_item_outside_for_each, Term), _)).

validate_time_unit(Unit0) :-
    text_atom(Unit0, Unit),
    memberchk(Unit, [year, month, day, hour]),
    !.
validate_time_unit(Unit) :-
    throw(error(domain_error(time_part_unit, Unit), _)).

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

:- discontiguous eval_action/5.

eval_action(emit(KeyExpr, ValueExpr), Document, Context, Key, Value) :-
    eval_expr(KeyExpr, Document, Context, Key),
    eval_expr(ValueExpr, Document, Context, Value).
eval_action(where(Condition, Action), Document, Context, Key, Value) :-
    eval_condition(Condition, Document, Context),
    eval_action(Action, Document, Context, Key, Value).
eval_action(all(Actions), Document, Context, Key, Value) :-
    member(Action, Actions),
    eval_action(Action, Document, Context, Key, Value).
eval_action(for_each(CollectionExpr, Action), Document, Context, Key, Value) :-
    eval_expr(CollectionExpr, Document, Context, Collection),
    must_be(list, Collection),
    ensure_collection_limit(Collection),
    member(Item, Collection),
    eval_action(Action, Document, [Item|Context], Key, Value).

eval_condition(true, _Document, _Context) :- !.
eval_condition(false, _Document, _Context) :- !, fail.
eval_condition(exists(Expr), Document, Context) :- !,
    eval_expr(Expr, Document, Context, _).
eval_condition(eq(Left, Right), Document, Context) :- !,
    eval_expr(Left, Document, Context, LeftValue),
    eval_expr(Right, Document, Context, RightValue),
    LeftValue == RightValue.
eval_condition(neq(Left, Right), Document, Context) :- !,
    eval_expr(Left, Document, Context, LeftValue),
    eval_expr(Right, Document, Context, RightValue),
    LeftValue \== RightValue.
eval_condition(gt(Left, Right), Document, Context) :- !,
    numeric_values(Left, Right, Document, Context, A, B),
    A > B.
eval_condition(gte(Left, Right), Document, Context) :- !,
    numeric_values(Left, Right, Document, Context, A, B),
    A >= B.
eval_condition(lt(Left, Right), Document, Context) :- !,
    numeric_values(Left, Right, Document, Context, A, B),
    A < B.
eval_condition(lte(Left, Right), Document, Context) :- !,
    numeric_values(Left, Right, Document, Context, A, B),
    A =< B.
eval_condition(and(Conditions), Document, Context) :- !,
    maplist(condition_on(Document, Context), Conditions).
eval_condition(or(Conditions), Document, Context) :- !,
    member(Condition, Conditions),
    eval_condition(Condition, Document, Context),
    !.
eval_condition(not(Condition), Document, Context) :-
    \+ eval_condition(Condition, Document, Context).

condition_on(Document, Context, Condition) :-
    eval_condition(Condition, Document, Context).

numeric_values(Left, Right, Document, Context, A, B) :-
    eval_expr(Left, Document, Context, A),
    eval_expr(Right, Document, Context, B),
    number(A),
    number(B).

eval_expr(field(Path), Document, _Context, Value) :-
    !,
    normalize_path(Path, Keys),
    field_path(Keys, Document, Value).
eval_expr(object(Pairs), Document, Context, Dict) :-
    !,
    maplist(eval_object_pair(Document, Context), Pairs, Evaluated),
    dict_create(Dict, json, Evaluated).
eval_expr(array(Values), Document, Context, Evaluated) :-
    !,
    maplist(expr_on(Document, Context), Values, Evaluated).
eval_expr(normalize_text(Expr), Document, Context, Normalized) :-
    !,
    eval_expr(Expr, Document, Context, Text),
    must_be(string, Text),
    ensure_text_limit(Text),
    normalize_visible_text(Text, Normalized).
eval_expr(lower(Expr), Document, Context, Lower) :-
    !,
    eval_expr(Expr, Document, Context, Text),
    must_be(string, Text),
    ensure_text_limit(Text),
    string_lower(Text, Lower).
eval_expr(tokens(Expr), Document, Context, Tokens) :-
    !,
    eval_expr(Expr, Document, Context, Text),
    must_be(string, Text),
    ensure_text_limit(Text),
    tokenize_text(Text, Tokens),
    ensure_token_limit(Tokens).
eval_expr(time_part(Unit0, Expr), Document, Context, Part) :-
    !,
    validate_time_unit(Unit0),
    text_atom(Unit0, Unit),
    eval_expr(Expr, Document, Context, Timestamp),
    must_be(number, Timestamp),
    timestamp_part(Timestamp, Unit, Part).
eval_expr(item, _Document, [Item|_], Item) :- !.
eval_expr(item(Path), _Document, [Item|_], Value) :-
    !,
    must_be(dict, Item),
    normalize_path(Path, Keys),
    field_path(Keys, Item, Value).
eval_expr(Value, _Document, _Context, Value) :-
    json_scalar(Value).

expr_on(Document, Context, Expr, Value) :-
    eval_expr(Expr, Document, Context, Value).

eval_object_pair(Document, Context, Key0-Expr, Key-Value) :-
    text_atom(Key0, Key),
    eval_expr(Expr, Document, Context, Value).

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

ensure_collection_limit(Collection) :-
    max_collection_items(Max),
    length(Collection, Count),
    (   Count =< Max
    ->  true
    ;   throw(error(resource_error(max_collection_items), _))
    ).

ensure_text_limit(Text) :-
    max_text_codepoints(Max),
    string_length(Text, Count),
    (   Count =< Max
    ->  true
    ;   throw(error(resource_error(max_text_codepoints), _))
    ).

ensure_token_limit(Tokens) :-
    max_tokens(Max),
    length(Tokens, Count),
    (   Count =< Max
    ->  true
    ;   throw(error(resource_error(max_tokens), _))
    ).

normalize_visible_text(Text, Normalized) :-
    string_codes(Text, Codes),
    strip_html_codes(Codes, outside, VisibleCodes0),
    decode_html_entities(VisibleCodes0, VisibleCodes),
    string_codes(Visible, VisibleCodes),
    normalize_space(string(Normalized), Visible),
    ensure_text_limit(Normalized).

strip_html_codes([], _State, []).
strip_html_codes([0'<|Rest], outside, [0' |Visible]) :-
    !,
    strip_html_codes(Rest, inside, Visible).
strip_html_codes([0'>|Rest], inside, [0' |Visible]) :-
    !,
    strip_html_codes(Rest, outside, Visible).
strip_html_codes([_Code|Rest], inside, Visible) :-
    !,
    strip_html_codes(Rest, inside, Visible).
strip_html_codes([Code|Rest], outside, [Code|Visible]) :-
    strip_html_codes(Rest, outside, Visible).

decode_html_entities([], []).
decode_html_entities(Codes, Decoded) :-
    html_entity_prefix(Codes, Replacement, Rest),
    !,
    append(Replacement, Tail, Decoded),
    decode_html_entities(Rest, Tail).
decode_html_entities([Code|Rest], [Code|Decoded]) :-
    decode_html_entities(Rest, Decoded).

html_entity_prefix(Codes, Replacement, Rest) :-
    member(Entity-ReplacementText,
           [ "&amp;"-"&",
             "&lt;"-"<",
             "&gt;"-">",
             "&quot;"-"\"",
             "&apos;"-"'",
             "&#39;"-"'",
             "&nbsp;"-" "
           ]),
    string_codes(Entity, Prefix),
    append(Prefix, Rest, Codes),
    string_codes(ReplacementText, Replacement).

tokenize_text(Text, Tokens) :-
    string_codes(Text, Codes),
    tokenize_codes(Codes, Tokens).

tokenize_codes(Codes, Tokens) :-
    drop_non_alnum(Codes, Rest),
    (   Rest == []
    ->  Tokens = []
    ;   take_alnum(Rest, TokenCodes, Tail),
        string_codes(Token, TokenCodes),
        Tokens = [Token|More],
        tokenize_codes(Tail, More)
    ).

drop_non_alnum([Code|Rest], Tail) :-
    \+ char_type(Code, alnum),
    !,
    drop_non_alnum(Rest, Tail).
drop_non_alnum(Codes, Codes).

take_alnum([Code|Rest], [Code|Token], Tail) :-
    char_type(Code, alnum),
    !,
    take_alnum(Rest, Token, Tail).
take_alnum(Rest, [], Rest).

timestamp_part(Timestamp, Unit, Part) :-
    stamp_date_time(Timestamp,
                    date(Year, Month, Day, Hour, _Minute, _Second,
                         _UTCOffset, _TimeZone, _DST),
                    'UTC'),
    time_part_value(Unit, Year, Month, Day, Hour, Part).

time_part_value(year, Year, _Month, _Day, _Hour, Year).
time_part_value(month, _Year, Month, _Day, _Hour, Month).
time_part_value(day, _Year, _Month, Day, _Hour, Day).
time_part_value(hour, _Year, _Month, _Day, Hour, Hour).

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
