# ElasticSearch script

Bash script to shrink the number of ElasticSearch shards by
 - Calculating size
 - Create a new index and copy the data with te [_shrink API ](https://www.elastic.co/guide/en/elasticsearch/reference/master/indices-shrink-index.html)
 - Removes the old index
 - Create an alias to the new index

The script produces only output based on your configuration. You can execute it yourself (or not 😼 ).

Optimal sizes are based on this blog post https://www.elastic.co/blog/how-many-shards-should-i-have-in-my-elasticsearch-cluster 

```
./shard_optimalisation.sh [-r] [-i filename] [-o]
```