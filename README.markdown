sqlite-srv
==========
 
Summary
-------

A simple daemon which open a sqlite database, and provide ways to interact with it, via:
lem-lrpc, or simple HTTP JSON POST.

Usage
-----

    # ./sqlite-srv.lua
    usage: ./sqlite-srv.lua
    Available options are:
      -h help                       Display this
      -l listen-socket-uri  []      listening socket uri, form 'unix://socket|tcp://*:1026'
      -r http-rest-api      []      http rest api, form '*:3333' )
      -s sqlite-db-path     [my.db] sqlite database file location
      -d debug                      debug


HTTP JSON POST example:
-----------------------

    $ ./sqlite-srv.lua -r '*:8080'
    -sqlite-srv starting-
    cwd: /woot/ra/prog/plop/sqlite-srv
    db path: my.db
    socket uri|path: 
    http rest api: *:8080
    
    $ curl -d '{"query":"create table bla (id INT, bladesc TEXT); "}' 'http://127.0.0.1:8080/exec'
    ["ok", true]

    $ curl -d '{"query":"create table bla (id INT, bladesc TEXT); "}' 'http://127.0.0.1:8080/exec'
    ["err","table bla already exists"]

    $ for i in {0..6} ; do \
        curl -d "{\"query\":\"insert into bla values(@id, @desc); \", \"arg\":{\"id\": $i, \"desc\": \"desc$i\"}}" 'http://127.0.0.1:8080/prepared_query' \
     ; done
    ["ok",true]["ok",true]["ok",true]["ok",true]["ok",true]["ok",true]["ok",true]

    $ curl -d "{\"query\":\"select * from bla ;\"}" 'http://127.0.0.1:8080/fetchall'
    ["ok",[[0,"desc0"],[1,"desc1"],[2,"desc2"],[3,"desc3"],[4,"desc4"],[5,"desc5"],[6,"desc6"]]]

    $ curl -d "{\"query\":\"select * from bla ;\"}" 'http://127.0.0.1:8080/prepared_query'
    ["ok",[0,"desc0"]]


License
-------

  Three clause BSD license


Contact
-------

  Please send bug reports, patches and feature requests to me <ra@apathie.net>.
