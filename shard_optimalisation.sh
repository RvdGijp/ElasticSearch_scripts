#!/bin/bash
set -e

# This is a script analyses the shard count and the heap space of all available indexes. 
# It does NOT modify your Elasticsearch. You will see your metrics and you can copy
# the output to your cluster to make the changes.
# Variables can be adjusted below.
# Requires sqlite3 and one MB local storage.
#
# Written by Ruud van der gijp <ruud.van.der.gijp@gmail.com> on 2019-05-28 The Netherlands
# It is compatible for ES 2.x till 7.x and can be re-runned at any time.

ES_NODE=http://127.0.0.1
ES_PORT=9200
SHARD_DB=/tmp/shards.db 
PRIME=(0 1 2 3 5 7 11 13 17 19 29 31 37 41 43 47 53 59 61 67 71 73 79 83 89 97 )

# Optimal sizes are based on this blog post; https://www.elastic.co/blog/how-many-shards-should-i-have-in-my-elasticsearch-cluster
MIN_SHARD_SIZE=$((20*1024*1024*1024)) # Shard min 20GB in bytes
MAX_SHARD_SIZE=$((40*1024*1024*1024)) # Shard max 40GB in bytes
MAX_SHARD_HEAP=$((1024/20)) # Max 20 shards per GB heap space

COLLECT_DATA=1
CREATE_OUTPUT=0

while getopts "ri:o" opt; do
  case ${opt} in
    r ) # Remove old db and start reading
      rm ${SHARD_DB}
      ;;
    i ) # Append dbfile and start reading
      SHARD_DB=$OPTARG
      ;;
    o ) # Skip reading and generate output based on db
      COLLECT_DATA=0
      CREATE_OUTPUT=1 
      ;;
    \? ) echo "Usage: shard_optimalisation.sh [-r] [-i filename] [-o]"
      echo ""
      exit
      ;;
  esac
done
shift $((OPTIND -1))

if [ " ${COLLECT_DATA} " == " 1 " ]; then
  sqlite3 ${SHARD_DB} "CREATE TABLE IF NOT EXISTS indices ( \
                        index_name, \
                        shard, \
                        rep, \
                        state, \
                        store,
                        min_shards,
                        max_shards) "

  sqlite3 ${SHARD_DB} "CREATE TABLE IF NOT EXISTS nodes ( \
                        node, \
                        heap) "

  function noPrime () {
    while [[ " ${PRIME[@]} " =~ " ${min_shards} " ]];
    do
     min_shards=$((min_shards+1))
    done
    while [[ " ${PRIME[@]} " =~ " ${max_shards} " ]];
    do
     ((++max_shards))
    done
    return
  }

  # Get the number of shards per index
  printf "\nReading your Elastic shard configuration.\n"
  mapfile -t shard < <(curl -sS -XGET "${ES_NODE}:${ES_PORT}/_cat/indices?bytes=b&h=index,status,pri,rep,health,pri.store.size")
  for line in "${shard[@]}"
  do
    shard_line=($line)
    index=${shard_line[0]}
    state=${shard_line[1]}
    shard=${shard_line[2]}
    rep=${shard_line[3]}
    health=${shard_line[4]}
    store=${shard_line[5]}
    # If index already in store skip this entry
    store=($(sqlite3 ${SHARD_DB} "SELECT 1 FROM indices WHERE index_name='${index}'"))
    if [ " ${store} " != " 1 " ]; then
      min_shards=$((($store+${MAX_SHARD_SIZE}-1)/${MAX_SHARD_SIZE}))
      max_shards=$((($store+${MIN_SHARD_SIZE}-1)/${MIN_SHARD_SIZE}))
      noPrime
      if [ " ${state} " == " close " ]; then
        printf "\nOpening closed index ${index}\n"
        response=0
        while [ " $response " != " 200 " ]; do
          response=$(curl --write-out %{http_code} --silent --output /dev/null -XPOST "${ES_NODE}:${ES_PORT}/${index}/_open?wait_for_active_shards=2")
        done
        mapfile -t closed_shard < <(curl -sS -XGET "${ES_NODE}:${ES_PORT}/_cat/indices/${index}?bytes=b&h=index,status,pri,rep,health,pri.store.size")
        for line in "${closed_shard[@]}"
        do
          shard_line=($line)
          index=${shard_line[0]}
          state=${shard_line[1]}
          shard=${shard_line[2]}
          rep=${shard_line[3]}
          health=${shard_line[4]}
          if [ " ${health} " == " red " ]; then
            store="NULL"
            min_shards="NULL"
            max_shards="NULL"
          else
            store=${shard_line[5]}
            min_shards=$((($store+${MAX_SHARD_SIZE}-1)/${MAX_SHARD_SIZE}))
            max_shards=$((($store+${MIN_SHARD_SIZE}-1)/${MIN_SHARD_SIZE}))
          fi
        done
        printf "\nClosing index ${index}\n"
        response=0
        while [ " $response " != " 200 " ]; do
          response=$(curl --write-out %{http_code} --silent --output /dev/null -XPOST "${ES_NODE}:${ES_PORT}/${index}/_close?wait_for_active_shards=2")
        done
      fi
      if [ " ${store} " != "  " ]; then
        sqlite3 ${SHARD_DB} "INSERT INTO indices (index_name,shard,rep,state,store,min_shards,max_shards) VALUES ('${index}','${shard}',${rep},'${state}',${store},${min_shards},${max_shards})"
      fi
    fi
  done
 
  # Get the available memory heap from the node
  mapfile -t shard < <(curl -sS -XGET "${ES_NODE}:${ES_PORT}/_cat/nodes?h=name,heap.max&bytes=b")
  for line in "${shard[@]}"
  do
    shard_line=($line)
    sqlite3 ${SHARD_DB} "INSERT INTO nodes (node,heap) VALUES('${shard_line[0]}','${shard_line[1]}');"
  done
  
  # Get sum of shard sizes
  printf "\nThe optimal number of shards based on storage, ATTENTION no considerations with prime numbers, command output does.\n"
  sqlite3 ${SHARD_DB} <<EOF
.mode column
.header on
.width 40
  SELECT index_name, (store/1024/1024)  || " MB" as size, shard as actual_num_shards,
  min_shards as min_num_shards_storage, 
  max_shards as max_num_shards_storage,
  (100/max_shards)*shard as percent
  FROM indices ORDER BY percent DESC;
EOF
fi
 
if [ " ${CREATE_OUTPUT} " == " 1 " ]; then
  # Get sum of heap sizes
  # Need _cat/shards for this info
  # printf "\nThe maximum number of shards bassed on the memory heap\n"
  # sqlite3 ${SHARD_DB} <<EOF
  # .mode column
  # .header on
  # SELECT node, count(*) as actual_number_shards_on_node,
  # heap/1024/1024/${MAX_SHARD_HEAP} as max_num_shards_heap,
  # CASE WHEN (heap/1024/1024/${MAX_SHARD_HEAP}) > count(*)
  # THEN ''
  # ELSE 'Increase memory or reduce the number of shards on this node.'
  # END as action
  # FROM nodes;
  # EOF
  
  # Commands that can be executed
  toModifyShard=($(sqlite3 ${SHARD_DB} <<EOF
.separator " "
  SELECT index_name, 
  min_shards as min_num_shards_storage,
  rep, 
  (100/max_shards)*shard as percent
  FROM indices WHERE percent>100 ORDER BY percent DESC limit 0,1;
EOF
  ))
  
  old_index_name="${toModifyShard[0]}"
  new_index_name="${toModifyShard[0]}-shrinked"
  new_num_shards="${toModifyShard[1]}"
  
  # toModifyNode=($(sqlite3 ${SHARD_DB} <<EOF
  # .separator " "
  # SELECT node, count(*) as replicas FROM shard WHERE shard='0' and prirep='r' and index_name='${old_index_name}' LIMIT 0,1;
  # EOF
  # ))
  # node_name="${toModifyNode[0]}"
  num_replicas="${toModifyShard[2]}"
  
  
  printf "\n\n\n# The Elastic shrink API cannot resize your index but it can copy it to an other index and make an alias to it.\n"
  printf "# Read https://www.elastic.co/guide/en/elasticsearch/reference/master/indices-shrink-index.html for more information.\n\n"
  #printf "# Make the index read-only.\n"
  #printf "curl -XPUT -H 'content-type: application/json' ${ES_NODE}:${ES_PORT}/${old_index_name}/_settings -d ' \n\
  # { \n\
  #  \"settings\": { \n\
  #    \"index.routing.allocation.require._name\": \"${node_name}\", \n\
  #    \"index.blocks.write\": true \n\
  #  } \n\
  #}'\n\n"
  printf "# Do the actual shrink.\n"
  printf "curl -XPOST -H 'content-type: application/json' ${ES_NODE}:${ES_PORT}/${old_index_name}/_shrink/${new_index_name} -d' \n\
  { \n\
    \"settings\": { \n\
      \"index.number_of_replicas\": ${num_replicas}, \n\
      \"index.number_of_shards\": ${new_num_shards}, \n\
      \"index.codec\": \"best_compression\" \n\
    }, \n\
    \"aliases\": { \n\
      \"my_search_indices\": { } \n\
    } \n\
  }'\n\n"
  
  # Wait for GET /_cluster/health?wait_for_status=yellow&timeout=50s
  
  printf "# Remove the old index.\n"
  printf "curl -XDELETE -H 'content-type: application/json' ${ES_NODE}:${ES_PORT}/${old_index_name}\n\n"
  
  printf "# Create an alias to redirect the old endpoint to the new one.\n"
  printf "curl -XPOST -H 'content-type: application/json' ${ES_NODE}:${ES_PORT}/_aliases -d' \
  { \n\
    \"actions\": [ \n\
      { \n\
        \"add\": { \n\
          \"index\": \"${new_index_name}\", \n\
          \"alias\": \"${old_index_name}\" \n\
        } \n\
      } \n\
    ] \n\
  }'\n"
fi
