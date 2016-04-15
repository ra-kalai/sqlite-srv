#!/usr/bin/env lem
-- sqlite-srv
-- Copyright (c) 2016, Ralph Augé
-- All rights reserved.
-- 
-- Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
-- 
-- 1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
-- 
-- 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
-- 
-- 3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.
-- 
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
--
--

local cmd = require 'lem.cmd'
local sqlite = require 'lem.sqlite3.queued'
local lfs = require 'lem.lfs'
local io = require 'lem.io'
local utils = require 'lem.utils'
local spawn = utils.spawn
local new_thread_queue = utils.new_thread_queue

local args = {
	last_arg = "",
	intro = "Available options are:",
	possible = {
		{'h', 'help', {desc="Display this", type='counter'}},
		{'l', 'listen-socket-uri', {desc="listening socket uri, form 'unix://socket|tcp://*:1026'", default_value=''}},
		{'r', 'http-rest-api', {desc="http rest api, form '*:3333' )", default_value=''}},
		{'s', 'sqlite-db-path', {desc="sqlite database file location", default_value='my.db'}},
		{'d', 'debug', {desc="debug", type='counter'}},
	},
}

local parg = cmd.parse_arg(args, arg)


local g_db_path = parg:get_last_val('sqlite-db-path')
local g_socket_uri = parg:get_last_val('listen-socket-uri')
local g_http_rest_api = parg:get_last_val('http-rest-api')
local g_debug = parg:is_flag_set('debug')

if parg.err or #parg.last_arg > 0
		or ( g_http_rest_api == '' and g_socket_uri == '') then
	cmd.display_usage(args, parg)
end

if parg:is_flag_set('help') then
	cmd.display_usage(args, {self_exe=arg[0]})
end

local format = string.format
print(format('-sqlite-srv starting-\n\z
							cwd: %s\n\z
							db path: %s\n\z
							socket uri|path: %s\n\z
							http rest api: %s',
							lfs.currentdir(), g_db_path, g_socket_uri, g_http_rest_api))

local db, err = sqlite.open(g_db_path, sqlite.CREATEREADWRITE)

if db == nil then
	io.stderr:write(
	format("could not open db [%s] err: ( %s ) ; check perm\n",
					g_db_path, err))
	os.exit(1)
end


local cmd_queue = new_thread_queue()

local function sqlite_srv_direct_prepared_query(query, v)
	local stmt, err = db:prepare(query)

	if stmt then
		local st = stmt:get()
		st:bind(v)
		local ret, err = st:step()

		if ret then
			stmt:put()
			stmt:finalize()
			return {'ok', ret}
		end
	end
	return {'err', err}
end

local function sqlite_srv_prepared_query(query, v)
	return cmd_queue:append(function ()
		return sqlite_srv_direct_prepared_query(query, v)
	end)
end

local function sqlite_srv_fetchall(query, v)
	local ret = cmd_queue:append(function ()
		local ok, msg = db:fetchall(query, v)
		if not ok then
			return {'err', msg}
		end
		return {'ok', ok}
	end)

  return ret
end

local function sqlite_srv_exec(sql)
	return cmd_queue:append(function ()
		local ok, msg = db:exec(sql)
		if not ok then
			return {'err', msg}
		end
		return {'ok', ok}
	end)
end

local function sqlite_srv_close()
	return cmd_queue:append(function ()
		db:close()
		spawn(function () os.exit(0) end)
		return {'ok'}
	end)
end

local function sqlite_srv_wrap_prepared_query_in_transaction(prepared_query_list)
	return cmd_queue:append(function ()
		local ok, msg = db:exec('BEGIN TRANSACTION;')
		if not ok then
			ret = {'err', msg}
			return
		end

		for i=1,#prepared_query_list do
			local query = prepared_query_list[i]
			sqlite_srv_direct_prepared_query(query[1], query[2])
		end

		local ok, msg = db:exec('COMMIT;')
		if not ok then
			ret = {'err', msg}
		end
	end)
end

if g_http_rest_api ~= '' then --% {
	local hathaway = require 'lem.hathaway'
	if g_debug then
		hathaway.debug = print
	else
		hathaway.debug = function () end
	end
	hathaway.import()

	local ljsonp = require 'ljsonp'
	local parse = ljsonp.parse
	local stringify = ljsonp.stringify

	local function hathaway_wrap(fun)
		local m = fun
		return function (req, res)
			res.headers['Content-Type'] = 'application/json'
			local body = req:body()
			local t = parse(body)

			if t == nil then
				res:add('["err", "invalid json"]')
				return
			end

			res:add(stringify(m(t.query, t.arg)))
		end
	end

	local http_api_method = {
		["/prepared_query"] = hathaway_wrap(sqlite_srv_prepared_query),
		["/fetchall"]       = hathaway_wrap(sqlite_srv_fetchall),
		["/exec"]           = hathaway_wrap(sqlite_srv_exec),
		["/close"]          = hathaway_wrap(sqlite_srv_close),
	}

	GET('/', function(req, res)
		res.headers['Content-Type'] = 'text/plain'
		res:add([[
API example:
curl -d '{"query":"select.. ", arg":{}}' 'http://srv/prepared_query'
curl -d '{"query":"select..", arg":{}}' 'http://srv/fetchall'
curl -d '{"query":"create table..."}' 'http://srv/exec'
curl -d '{}' 'http://srv/close'
]])
	end)

	for k, v in pairs(http_api_method) do
		POST(k, v)
	end

	spawn(function ()
		Hathaway(g_http_rest_api:match("([^:]+):([^:]+)"))
	end)
end --% }

if g_socket_uri ~= '' then --% {
	local lrpc = require 'lem.lrpc'
	lrpc.server.import()

	local function rpc_single_arity_wrap(fun)
		local m = fun
		return function (arg)
			m(arg.query, arg.args)
		end
	end

	declare_rpc_fun('fast_prepared_query', rpc_single_arity_wrap(sqlite_srv_prepared_query))
	declare_rpc_fun('fast_fetchall', rpc_single_arity_wrap(sqlite_srv_fetchall))
	declare_rpc_fun('fast_exec', rpc_single_arity_wrap(sqlite_srv_exec))
	declare_rpc_fun('fast_close', rpc_single_arity_wrap(sqlite_srv_close))

	declare_rpc_fun('prepared_query', sqlite_srv_prepared_query)
	declare_rpc_fun('wrap_prepared_query_in_transaction', sqlite_srv_wrap_prepared_query_in_transaction)
	declare_rpc_fun('fetchall', sqlite_srv_fetchall)
	declare_rpc_fun('exec', sqlite_srv_exec)
	declare_rpc_fun('close', sqlite_srv_close)

	print('rpc-server starting')
	spawn(function ()
		local run, err, extra = run_rpc_server(g_socket_uri)

		if not run then
			io.stderr:write(
				format("socket binding problem [%s] err: ( %s - %s) ; check perm\n",
					g_socket_uri, err, extra))
			os.exit(2)
		end
	end)
end --% }
