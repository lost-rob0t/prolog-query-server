:- module(expert_system,
          [ replace_kb/3,
            upsert_document/3,
            remove_document/2,
            run_query/4,
            validate_document/1,
            knowledge_base_loaded/1
          ]).

:- use_module(library(option)).
:- use_module(library(error)).
:- use_module(library(solution_sequences)).

:- dynamic kb_clause/4.
:- dynamic kb_loaded/1.

replace_kb(KB, Documents, Stats) :-
    retractall(kb_clause(KB, _, _, _)),
    retractall(kb_loaded(KB)),
    load_documents(Documents, KB, 0, 0, 0, Facts, Rules, Skipped),
    assertz(kb_loaded(KB)),
    Stats = _{facts:Facts, rules:Rules, skipped_disabled:Skipped}.

upsert_document(KB, Document, Outcome) :-
    required(Document, '_id', Source),
    (   document_enabled(Document)
    ->  document_kind(Document, Kind),
        validate_kind(Kind, Document),
        retractall(kb_clause(KB, _, _, Source)),
        assert_document_clause(Kind, KB, Document),
        Outcome = Kind
    ;   retractall(kb_clause(KB, _, _, Source)),
        Outcome = disabled
    ).

remove_document(KB, Source) :-
    retractall(kb_clause(KB, _, _, Source)).

run_query(KB, Query, Options, Result) :-
    (   kb_loaded(KB)
    ->  true
    ;   throw(error(existence_error(knowledge_base, KB), _))
    ),
    decode_goal(Query, Goal, [], VarsReversed),
    reverse(VarsReversed, Vars),
    option(max_depth(MaxDepth), Options, 32),
    option(max_solutions(MaxSolutions), Options, 100),
    option(trace(Trace), Options, false),
    positive_integer(max_depth, MaxDepth),
    positive_integer(max_solutions, MaxSolutions),
    findnsols(MaxSolutions,
              Solution,
              query_solution(KB, Goal, Vars, MaxDepth, Trace, Solution),
              Solutions),
    length(Solutions, Count),
    Result = _{kb:KB, count:Count, solutions:Solutions}.

knowledge_base_loaded(KB) :-
    kb_loaded(KB).

positive_integer(_Name, Value) :-
    integer(Value),
    Value > 0,
    !.
positive_integer(Name, Value) :-
    throw(error(domain_error(positive_integer(Name), Value), _)).

validate_document(Document) :-
    document_kind(Document, Kind),
    validate_kind(Kind, Document).

validate_kind(fact, Document) :-
    fact_clause(Document, _Head, _Body, _Source).
validate_kind(rule, Document) :-
    rule_clause(Document, _Head, _Body, _Source).

load_documents([], _KB, Facts, Rules, Skipped, Facts, Rules, Skipped).
load_documents([Document|Rest], KB, Facts0, Rules0, Skipped0, Facts, Rules, Skipped) :-
    (   document_enabled(Document)
    ->  document_kind(Document, Kind),
        load_document(Kind, KB, Document, Facts0, Rules0, Facts1, Rules1),
        Skipped1 = Skipped0
    ;   Facts1 = Facts0,
        Rules1 = Rules0,
        Skipped1 is Skipped0 + 1
    ),
    load_documents(Rest, KB, Facts1, Rules1, Skipped1, Facts, Rules, Skipped).

load_document(fact, KB, Document, Facts0, Rules, Facts, Rules) :-
    fact_clause(Document, Head, Body, Source),
    assertz(kb_clause(KB, Head, Body, Source)),
    Facts is Facts0 + 1.
load_document(rule, KB, Document, Facts, Rules0, Facts, Rules) :-
    rule_clause(Document, Head, Body, Source),
    assertz(kb_clause(KB, Head, Body, Source)),
    Rules is Rules0 + 1.

assert_document_clause(fact, KB, Document) :-
    fact_clause(Document, Head, Body, Source),
    assertz(kb_clause(KB, Head, Body, Source)).
assert_document_clause(rule, KB, Document) :-
    rule_clause(Document, Head, Body, Source),
    assertz(kb_clause(KB, Head, Body, Source)).

fact_clause(Document, Head, [], Source) :-
    require_type(Document, "prolog_fact"),
    required(Document, predicate, Predicate),
    optional(Document, args, [], Args),
    GoalDict = _{predicate:Predicate, args:Args},
    decode_goal(GoalDict, Head, [], Vars),
    (   Vars == [],
        ground(Head)
    ->  true
    ;   throw(error(domain_error(ground_fact, Document), _))
    ),
    document_source(Document, Source).

rule_clause(Document, Head, Body, Source) :-
    require_type(Document, "prolog_rule"),
    required(Document, head, HeadDict),
    optional(Document, body, [], BodyDicts),
    must_be(list, BodyDicts),
    decode_goal(HeadDict, Head, [], Vars0),
    decode_body(BodyDicts, Body, Vars0, _Vars),
    document_source(Document, Source).
decode_body([], [], Vars, Vars).
decode_body([Item|Rest], [Goal|Goals], Vars0, Vars) :-
    decode_body_item(Item, Goal, Vars0, Vars1),
    decode_body(Rest, Goals, Vars1, Vars).

decode_body_item(Item, not(Goal), Vars0, Vars) :-
    is_dict(Item),
    get_dict(not, Item, Negated),
    !,
    decode_goal(Negated, Goal, Vars0, Vars).
decode_body_item(Item, Goal, Vars0, Vars) :-
    decode_goal(Item, Goal, Vars0, Vars).

decode_goal(Dict, goal(Predicate, Args), Vars0, Vars) :-
    must_be(dict, Dict),
    required(Dict, predicate, PredicateValue),
    as_atom(PredicateValue, Predicate),
    valid_predicate(Predicate),
    optional(Dict, args, [], Nodes),
    must_be(list, Nodes),
    decode_nodes(Nodes, Args, Vars0, Vars).

decode_nodes([], [], Vars, Vars).
decode_nodes([Node|Rest], [Value|Values], Vars0, Vars) :-
    decode_node(Node, Value, Vars0, Vars1),
    decode_nodes(Rest, Values, Vars1, Vars).

decode_node(Node, Value, Vars0, Vars) :-
    (   is_dict(Node), get_dict(var, Node, Name0)
    ->  variable_name(Name0, Name),
        intern_variable(Name, Value, Vars0, Vars)
    ;   is_dict(Node), get_dict(atom, Node, Atom0)
    ->  as_atom(Atom0, Value),
        Vars = Vars0
    ;   is_dict(Node), get_dict(functor, Node, Functor0)
    ->  as_atom(Functor0, Functor),
        valid_predicate(Functor),
        optional(Node, args, [], ArgNodes),
        must_be(list, ArgNodes),
        decode_nodes(ArgNodes, CompoundArgs, Vars0, Vars),
        Value =.. [Functor|CompoundArgs]
    ;   is_dict(Node)
    ->  throw(error(domain_error(term_ast, Node), _))
    ;   Value = Node,
        Vars = Vars0
    ).

intern_variable(Name, Variable, Vars, Vars) :-
    memberchk(Name-Existing, Vars),
    !,
    Variable = Existing.
intern_variable(Name, Variable, Vars0, [Name-Variable|Vars0]).

query_solution(KB, Goal, Vars, MaxDepth, TraceEnabled, Solution) :-
    solve_goal(KB, Goal, 0, MaxDepth, Sources),
    bindings_dict(Vars, Bindings),
    (   TraceEnabled == true
    ->  Solution = _{bindings:Bindings, sources:Sources}
    ;   Solution = _{bindings:Bindings}
    ).

solve_goal(_KB, goal(eq, [Left, Right]), _Depth, _MaxDepth, []) :-
    !,
    Left = Right.
solve_goal(_KB, goal(neq, [Left, Right]), _Depth, _MaxDepth, []) :-
    !,
    dif(Left, Right).
solve_goal(KB, Goal, Depth, MaxDepth, [Source|Sources]) :-
    Depth < MaxDepth,
    kb_clause(KB, Head0, Body0, Source),
    copy_term((Head0, Body0), (Head, Body)),
    Goal = Head,
    NextDepth is Depth + 1,
    solve_body(KB, Body, NextDepth, MaxDepth, Sources).

solve_body(_KB, [], _Depth, _MaxDepth, []).
solve_body(KB, [not(Goal)|Rest], Depth, MaxDepth, Sources) :-
    !,
    \+ solve_goal(KB, Goal, Depth, MaxDepth, _),
    solve_body(KB, Rest, Depth, MaxDepth, Sources).
solve_body(KB, [Goal|Rest], Depth, MaxDepth, Sources) :-
    solve_goal(KB, Goal, Depth, MaxDepth, HeadSources),
    solve_body(KB, Rest, Depth, MaxDepth, TailSources),
    append(HeadSources, TailSources, Sources).

bindings_dict(Vars, Dict) :-
    maplist(binding_pair, Vars, Pairs),
    dict_create(Dict, bindings, Pairs).

binding_pair(Name-Value, Key-Encoded) :-
    atom_string(Key, Name),
    encode_value(Value, Encoded).

encode_value(Value, _{unbound:true}) :-
    var(Value),
    !.
encode_value(Value, Encoded) :-
    atomic(Value),
    !,
    atom_json_value(Value, Encoded).
encode_value(Value, _{functor:FunctorString, args:EncodedArgs}) :-
    compound(Value),
    Value =.. [Functor|Args],
    atom_string(Functor, FunctorString),
    maplist(encode_value, Args, EncodedArgs).

atom_json_value(Value, String) :-
    atom(Value),
    Value \== true,
    Value \== false,
    Value \== null,
    !,
    atom_string(Value, String).
atom_json_value(Value, Value).

document_kind(Document, fact) :-
    require_type(Document, "prolog_fact"),
    !.
document_kind(Document, rule) :-
    require_type(Document, "prolog_rule"),
    !.
document_kind(Document, _) :-
    throw(error(domain_error(prolog_document_type, Document), _)).

document_enabled(Document) :-
    optional(Document, enabled, true, Enabled),
    Enabled \== false.

document_source(Document, Source) :-
    (   get_dict('_id', Document, Source0)
    ->  Source = Source0
    ;   Source = "unsaved"
    ).

require_type(Document, Expected) :-
    required(Document, type, Actual),
    (   text_equal(Actual, Expected)
    ->  true
    ;   fail
    ).

required(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   throw(error(existence_error(key, Key), _))
    ).

optional(Dict, Key, Default, Value) :-
    (   get_dict(Key, Dict, Value0)
    ->  Value = Value0
    ;   Value = Default
    ).

as_atom(Value, Atom) :-
    (   atom(Value)
    ->  Atom = Value
    ;   string(Value)
    ->  atom_string(Atom, Value)
    ;   throw(error(type_error(text, Value), _))
    ).

variable_name(Value, Name) :-
    (   string(Value)
    ->  Name = Value
    ;   atom(Value)
    ->  atom_string(Value, Name)
    ;   throw(error(type_error(variable_name, Value), _))
    ),
    string_length(Name, Length),
    Length > 0.

valid_predicate(Predicate) :-
    atom_codes(Predicate, Codes),
    Codes = [First|Rest],
    predicate_start(First),
    maplist(predicate_continue, Rest),
    !.
valid_predicate(Predicate) :-
    throw(error(domain_error(predicate_name, Predicate), _)).

predicate_start(Code) :-
    code_type(Code, lower),
    !.
predicate_start(0'_).

predicate_continue(Code) :-
    code_type(Code, alnum),
    !.
predicate_continue(0'_).

text_equal(Left, Right) :-
    as_atom(Left, LeftAtom),
    as_atom(Right, RightAtom),
    LeftAtom == RightAtom.
