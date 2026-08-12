:- initialization(main, main).

main :-
    load_files(['expert_system_tests.pl',
                'resource_limits_tests.pl',
                'proof_tree_tests.pl',
                'builtin_tests.pl',
                'kb_analysis_tests.pl',
                'query_server_protocol_tests.pl'],
               [silent(true)]),
    (   run_tests
    ->  halt(0)
    ;   halt(1)
    ).
