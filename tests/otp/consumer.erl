-module(otp_consumer).
-export([main/1]).
main([Catalog, Library, Marker, Output]) ->
    {ok, Bytes} = file:read_file(Catalog),
    Model = json:decode(Bytes),
    true = unicode:characters_to_binary(code:root_dir()) =:= maps:get(<<"runtimeRoot">>, Model),
    ExpectedElixir = filename:join([binary_to_list(maps:get(<<"elixirRoot">>, Model)), "lib", "elixir", "lib", "elixir"]),
    {ok, ElixirSdkApp} = file:read_file(filename:join([ExpectedElixir, "ebin", "elixir.app"])),
    {ok, ElixirSdkApp} = file:read_file(filename:join([code:lib_dir(elixir), "ebin", "elixir.app"])),
    {ok, _} = application:ensure_all_started(shouter),
    Values = ['Elixir.Shouter':shout(V) || V <- [<<"42">>, <<"43">>]],
    Expected = [unicode:characters_to_binary("{\"GREETING\":\"" ++ Marker ++ ", " ++ V ++ "\"}") || V <- ["42", "43"]],
    case Values =:= Expected of
        true -> ok;
        false -> error({genuine_compiled_behavior_mismatch, Values})
    end,
    Apps = [A || A <- maps:get(<<"applications">>, Model), not maps:get(<<"sdk">>, A)],
    Origins = lists:append([origins(A, Library) || A <- Apps]),
    Result = #{
        elixirLibrary => unicode:characters_to_binary(code:lib_dir(elixir)),
        otp => unicode:characters_to_binary(erlang:system_info(otp_release)),
        erts => unicode:characters_to_binary(erlang:system_info(version)),
        values => Values,
        origins => Origins
    },
    ok = file:write_file(Output, json:encode(Result)).
origins(App, Library) ->
    Name = binary_to_list(maps:get(<<"name">>, App)),
    Version = binary_to_list(maps:get(<<"version">>, App)),
    [
        begin
            Module = binary_to_atom(maps:get(<<"name">>, M)),
            {module, Module} = code:ensure_loaded(Module),
            Path = code:which(Module),
            Expected = filename:join([
                Library, Name ++ "-" ++ Version, "ebin", atom_to_list(Module) ++ ".beam"
            ]),
            true = filename:absname(Path) =:= filename:absname(Expected),
            {Module, Object, Path} = code:get_object_code(Module),
            Sha = string:lowercase(binary:encode_hex(crypto:hash(sha256, Object))),
            true = Sha =:= maps:get(<<"sha256">>, M),
            MD5 = binary:encode_hex(Module:module_info(md5)),
            true = MD5 =:= maps:get(<<"codeMD5">>, M),
            #{
                module => atom_to_binary(Module),
                path => unicode:characters_to_binary(Path),
                sha256 => Sha,
                codeMD5 => MD5
            }
        end
     || M <- maps:get(<<"modules">>, App)
    ].
