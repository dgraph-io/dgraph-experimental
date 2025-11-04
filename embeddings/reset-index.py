# !pip install  pydgraph python_graphql_client 
import sys
import json
import os
import re
import pydgraph


# reset the index all embedding predicates or of one provided predicate name
# Should be replaced by Deploying the GraphQL Schema without indexes and then deploying with the Indexes.
# 
global client # dgrpah client is a global variable

assert "DGRAPH_GRPC" in os.environ, "DGRAPH_GRPC must be defined"
dgraph_grpc = os.environ["DGRAPH_GRPC"]
if "cloud.dgraph" in dgraph_grpc:
    assert "DGRAPH_ADMIN_KEY" in os.environ, "DGRAPH_ADMIN_KEY must be defined"
    APIAdminKey = os.environ["DGRAPH_ADMIN_KEY"]
else:
    APIAdminKey = None

# TRANSFORMER_API_KEY must be defined in env variables
# client stub for on-prem requires grpc host:port without protocol
# client stub for cloud requires the grpc endpoint of graphql endpoint or base url of the cluster
# to run on a self-hosted env, unset ADMIN_KEY and set DGRAPH_GRPC

def setClient():
    global client
    if APIAdminKey is None:
      client_stub = pydgraph.DgraphClientStub(dgraph_grpc)
    else:
        client_stub = pydgraph.DgraphClientStub.from_cloud(dgraph_grpc,APIAdminKey )     
    client = pydgraph.DgraphClient(client_stub)

def clearIndex(predicate):
    print(f"remove index for {predicate}")
    schema = f"{predicate}: float32vector ."
    op = pydgraph.Operation(schema=schema)
    alter = client.alter(op)
    print(alter)
def computeIndex(predicate,index):
    print(f"create index for {predicate} {index}")
    schema = f"{predicate}: float32vector @index({index}) ."
    op = pydgraph.Operation(schema=schema)
    alter = client.alter(op)
    print(alter) 



if len(sys.argv) == 3:
    requested_predicate = sys.argv[2]
    print(f"Reindexing {requested_predicate} in {dgraph_grpc}")
else:
    requested_predicate = None    
    print(f"Reindexing all embeddings predicates  in {dgraph_grpc}")
    

confirm = input("Continue (y/n)?")



if confirm == "y":
    setClient()
    
    with open("./embeddings.json") as f:
        data = f.read()
        hm_config = json.loads(data)
        for embedding_def in hm_config['embeddings']:
            predicate = f"{embedding_def['entityType']}.{embedding_def['attribute']}"
            if requested_predicate == None or requested_predicate == predicate:
                index = embedding_def['index']
                clearIndex(predicate)
                computeIndex(predicate,index)
