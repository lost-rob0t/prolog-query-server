:- module(auth,
          [ authorize/2,
            auth_status/1,
            constant_time_token_equal/2
          ]).

:- use_module(library(crypto)).
:- use_module(config).

authorize(_Request, _Capability) :-
    config:api_auth_mode(off),
    !.
authorize(Request, Capability) :-
    config:api_auth_mode(required),
    bearer_token(Request, Supplied),
    authorize_token(Capability, Supplied),
    !.
authorize(_Request, Capability) :-
    throw(error(permission_error(access, api_capability, Capability), _)).

auth_status(Status) :-
    config:api_auth_mode(Mode),
    (   Mode == off
    ->  Status = _{mode:"off", configured:true}
    ;   token_configured('PQS_READ_TOKEN', ReadConfigured),
        token_configured('PQS_WRITE_TOKEN', WriteConfigured),
        (ReadConfigured == true, WriteConfigured == true -> Configured = true ; Configured = false),
        Status = _{mode:"required",
                   configured:Configured,
                   read_token_configured:ReadConfigured,
                   write_token_configured:WriteConfigured}
    ).

authorize_token(write, Supplied) :-
    config:api_write_token(Expected),
    constant_time_token_equal(Supplied, Expected).
authorize_token(read, Supplied) :-
    (   config:api_read_token(ReadToken),
        constant_time_token_equal(Supplied, ReadToken)
    ->  true
    ;   config:api_write_token(WriteToken),
        constant_time_token_equal(Supplied, WriteToken)
    ).
authorize_token(Capability, _Supplied) :-
    throw(error(domain_error(api_capability, Capability), _)).

bearer_token(Request, Token) :-
    memberchk(authorization(Header0), Request),
    text_string(Header0, Header),
    string_concat("Bearer ", Token, Header),
    Token \== "".

constant_time_token_equal(Left0, Right0) :-
    text_string(Left0, Left),
    text_string(Right0, Right),
    crypto_data_hash(Left, LeftHash, [algorithm(sha256)]),
    crypto_data_hash(Right, RightHash, [algorithm(sha256)]),
    atom_codes(LeftHash, LeftCodes),
    atom_codes(RightHash, RightCodes),
    constant_codes_equal(LeftCodes, RightCodes, 0, Difference),
    Difference =:= 0.

constant_codes_equal([], [], Difference, Difference).
constant_codes_equal([A|As], [B|Bs], Difference0, Difference) :-
    Difference1 is Difference0 \/ (A xor B),
    constant_codes_equal(As, Bs, Difference1, Difference).

token_configured(Name, true) :-
    getenv(Name, Value),
    Value \== '',
    !.
token_configured(_Name, false).

text_string(Value, String) :-
    (   string(Value)
    ->  String = Value
    ;   atom(Value)
    ->  atom_string(Value, String)
    ;   throw(error(type_error(text, Value), _))
    ).
