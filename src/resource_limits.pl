:- module(resource_limits,
          [ effective_query_budget/2,
            validate_document/1,
            validate_snapshot/1,
            validate_proof_totals/3,
            json_bytes/2,
            resource_limit/2
          ]).

:- use_module(library(error)).
:- use_module(library(http/json)).
:- use_module(library(utf8)).
:- use_module(config).

effective_query_budget(Input, Budget) :-
    must_be(dict, Input),
    input_budget_dict(Input, Requested),
    config:query_timeout_ms(TimeoutCap),
    config:max_query_depth(DepthCap),
    config:max_query_solutions(SolutionsCap),
    config:max_inference_steps(InferenceCap),
    config:max_proof_nodes(ProofNodesCap),
    config:max_proof_bytes(ProofBytesCap),
    effective_value(Input, Requested, timeout_ms, TimeoutCap, TimeoutMs),
    effective_value(Input, Requested, max_depth, DepthCap, MaxDepth),
    effective_value(Input, Requested, max_solutions, SolutionsCap, MaxSolutions),
    effective_value(Input, Requested, max_inference_steps, InferenceCap, MaxInferenceSteps),
    effective_value(Input, Requested, max_proof_nodes, ProofNodesCap, MaxProofNodes),
    effective_value(Input, Requested, max_proof_bytes, ProofBytesCap, MaxProofBytes),
    Budget = _{timeout_ms:TimeoutMs,
               max_depth:MaxDepth,
               max_solutions:MaxSolutions,
               max_inference_steps:MaxInferenceSteps,
               max_proof_nodes:MaxProofNodes,
               max_proof_bytes:MaxProofBytes}.

input_budget_dict(Input, Budget) :-
    (   get_dict(budget, Input, Raw)
    ->  must_be(dict, Raw),
        Budget = Raw
    ;   Budget = _{}
    ).

effective_value(Input, Budget, Key, Cap, Value) :-
    (   get_dict(Key, Budget, Requested)
    ->  true
    ;   get_dict(Key, Input, Requested)
    ->  true
    ;   Requested = Cap
    ),
    positive_integer(Key, Requested),
    Value is min(Requested, Cap).

positive_integer(_Key, Value) :-
    integer(Value),
    Value > 0,
    !.
positive_integer(Key, Value) :-
    throw(error(domain_error(positive_integer(Key), Value), _)).

validate_document(Document) :-
    must_be(dict, Document),
    config:max_document_bytes(MaxBytes),
    json_bytes(Document, Bytes),
    (   Bytes =< MaxBytes
    ->  true
    ;   resource_limit(document_size,
                       _{max_bytes:MaxBytes, actual_bytes:Bytes})
    ),
    validate_rule_goals(Document).

validate_rule_goals(Document) :-
    (   get_dict(type, Document, Type),
        text_equal(Type, "prolog_rule")
    ->  (   get_dict(body, Document, Body)
        ->  must_be(list, Body)
        ;   Body = []
        ),
        length(Body, Goals),
        config:max_rule_goals(MaxGoals),
        (   Goals =< MaxGoals
        ->  true
        ;   resource_limit(rule_goal_count,
                           _{max_goals:MaxGoals, actual_goals:Goals})
        )
    ;   true
    ).

validate_snapshot(Documents) :-
    must_be(list, Documents),
    length(Documents, Count),
    config:max_kb_documents(MaxDocuments),
    (   Count =< MaxDocuments
    ->  true
    ;   resource_limit(kb_document_count,
                       _{max_documents:MaxDocuments, actual_documents:Count})
    ),
    maplist(validate_document, Documents),
    snapshot_bytes(Documents, 0, Bytes),
    config:max_kb_bytes(MaxBytes),
    (   Bytes =< MaxBytes
    ->  true
    ;   resource_limit(kb_size,
                       _{max_bytes:MaxBytes, actual_bytes:Bytes})
    ).

snapshot_bytes([], Bytes, Bytes).
snapshot_bytes([Document|Rest], Bytes0, Bytes) :-
    json_bytes(Document, DocumentBytes),
    Bytes1 is Bytes0 + DocumentBytes,
    config:max_kb_bytes(MaxBytes),
    (   Bytes1 =< MaxBytes
    ->  snapshot_bytes(Rest, Bytes1, Bytes)
    ;   resource_limit(kb_size,
                       _{max_bytes:MaxBytes, actual_bytes:Bytes1})
    ).

validate_proof_totals(Nodes, Bytes, QueryId) :-
    config:max_proof_nodes(MaxNodes),
    config:max_proof_bytes(MaxBytes),
    (   Nodes =< MaxNodes
    ->  true
    ;   throw(error(pqs_query_resource(proof_limit,
                                       QueryId,
                                       _{max_proof_nodes:MaxNodes,
                                         actual_proof_nodes:Nodes}),
                      _))
    ),
    (   Bytes =< MaxBytes
    ->  true
    ;   throw(error(pqs_query_resource(proof_limit,
                                       QueryId,
                                       _{max_proof_bytes:MaxBytes,
                                         actual_proof_bytes:Bytes}),
                      _))
    ).

json_bytes(Dict, Bytes) :-
    must_be(dict, Dict),
    atom_json_dict(Text, Dict, [as(atom)]),
    atom_codes(Text, Codes),
    phrase(utf8_codes(Codes), Octets),
    length(Octets, Bytes).

resource_limit(Code, Limit) :-
    throw(error(pqs_resource_limit(Code, Limit), _)).

text_equal(Value, Text) :-
    (   string(Value)
    ->  Value == Text
    ;   atom(Value)
    ->  atom_string(Value, Text)
    ;   false
    ).
