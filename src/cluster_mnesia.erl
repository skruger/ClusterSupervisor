%% Author: skruger
%% Created: Nov 5, 2011
%% Description: TODO: Add description to cluster_mnesia
-module(cluster_mnesia).

%%
%% Include files
%%

%%
%% Exported Functions
%%
-export([table_copies/0,table_copies/1]).
-export([get_table_copy_type/2]).

%%
%% API Functions
%%

table_copies() ->
    Tables = mnesia:system_info(tables),
    lists:flatmap(fun(T) ->
                    [{T,N,disc_copies} || N <- mnesia:table_info(T,disc_copies)] ++
                    [{T,N,disc_only_copies} || N <- mnesia:table_info(T,disc_only_copies)] ++
                    [{T,N,ram_copies} || N <- mnesia:table_info(T,ram_copies)]
                end,Tables).

table_copies({Node,Table}) ->
    lists:filter(fun({T,N,_}) when N == Node, T == Table ->
						 true;
					(_) ->
						 false
				 end,
				 table_copies());
table_copies(Node) ->
    lists:filter(fun({_,N,_}) when N == Node -> true;
					(_) ->
						 false
				 end,
				 table_copies()).

get_table_copy_type(Node,Table) ->
	case table_copies({Node,Table}) of
		[{_,_,Type}|_] ->
			Type;
		[] ->
			no_copy
	end.

%%
%% Local Functions
%%

