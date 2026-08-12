:- begin_tests(metrics).

:- use_module('../src/metrics').
:- use_module('../src/observability').

counter_value(Snapshot, Name, Labels, Value) :-
    get_dict(counters, Snapshot, Counters),
    member(Metric, Counters),
    get_dict(name, Metric, Name),
    get_dict(labels, Metric, Labels),
    get_dict(value, Metric, Value).

gauge_value(Snapshot, Name, Labels, Value) :-
    get_dict(gauges, Snapshot, Gauges),
    member(Metric, Gauges),
    get_dict(name, Metric, Name),
    get_dict(labels, Metric, Labels),
    get_dict(value, Metric, Value).

test(records_http_query_refresh_and_write_metrics) :-
    reset_metrics,
    observe_http(query, success, 0.25),
    observe_query(_{count:2}, [max_solutions(2)]),
    observe_refresh(_{sync_mode:"full", documents:17}),
    observe_refresh(_{sync_mode:"changes",
                      changes_seen:3,
                      knowledge_applied:2,
                      knowledge_removed:1}),
    increment_knowledge_write(fact_create),
    snapshot(Snapshot),
    counter_value(Snapshot, http_requests, endpoint_outcome(query, success), 1),
    counter_value(Snapshot, query_requests, all, 1),
    counter_value(Snapshot, query_solutions, all, 2),
    counter_value(Snapshot, query_solution_limit_hits, all, 1),
    counter_value(Snapshot, kb_full_reloads, all, 1),
    counter_value(Snapshot, kb_changes_syncs, all, 1),
    counter_value(Snapshot, kb_changes_seen, all, 3),
    counter_value(Snapshot, kb_changes_applied, all, 2),
    counter_value(Snapshot, kb_changes_removed, all, 1),
    counter_value(Snapshot, knowledge_writes, fact_create, 1),
    gauge_value(Snapshot, query_last_solutions, all, 2),
    gauge_value(Snapshot, kb_last_snapshot_documents, all, 17),
    gauge_value(Snapshot, kb_last_changes_seen, all, 3).

test(classifies_couchdb_conflicts) :-
    reset_metrics,
    observe_error(error(couchdb_error(409, _{error:"conflict"}), context)),
    snapshot(Snapshot),
    counter_value(Snapshot, api_errors, all, 1),
    counter_value(Snapshot, couchdb_errors, all, 1),
    counter_value(Snapshot, couchdb_conflicts, all, 1),
    counter_value(Snapshot, error_class, couchdb_conflict, 1).

test(prometheus_output_contains_only_registered_labels) :-
    reset_metrics,
    observe_http(query, success, 0.125),
    increment_knowledge_write(rule_create),
    prometheus_text(Text),
    sub_atom(Text, _, _, _, 'pqs_http_requests_total{endpoint="query",outcome="success"}'),
    sub_atom(Text, _, _, _, 'pqs_http_request_duration_seconds_sum{endpoint="query"}'),
    sub_atom(Text, _, _, _, 'pqs_knowledge_writes_total{class="rule_create"}'),
    \+ sub_atom(Text, _, _, _, 'secret-predicate-value').

test(reset_clears_registry) :-
    reset_metrics,
    observe_http(query, success, 0.1),
    reset_metrics,
    snapshot(_{counters:[], sums:[], gauges:[]}).

test(request_ids_are_unique) :-
    new_request_id(A),
    new_request_id(B),
    A \== B.

:- end_tests(metrics).
