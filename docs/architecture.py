#!/usr/bin/env python3
"""
Generate AWS architecture diagram for CDC lakehouse.
Requires: pip3 install diagrams graphviz
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.aws.database import RDSPostgresqlInstance
from diagrams.aws.analytics import Glue, Athena, KinesisDataStreams
from diagrams.aws.storage import S3
from diagrams.aws.compute import EC2
from diagrams.aws.network import InternetGateway, Endpoint
from diagrams.aws.security import SecretsManager
import os

# Change to docs directory
os.chdir(os.path.dirname(os.path.abspath(__file__)))

graph_attr = {
    "fontsize": "14",
    "bgcolor": "white",
    "pad": "0.5",
}

with Diagram(
    "CDC Lakehouse Architecture",
    filename="architecture",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=graph_attr
):
    
    with Cluster("VPC (10.0.0.0/16)"):
        
        with Cluster("Public Subnet"):
            bastion = EC2("Bastion\n(t3.micro)")
            igw = InternetGateway("Internet\nGateway")
            igw >> bastion
        
        with Cluster("Private Subnets (2 AZs)"):
            
            with Cluster("Data Source"):
                rds = RDSPostgresqlInstance(
                    "RDS Postgres 16\n" +
                    "db.t4g.micro\n" +
                    "Logical Replication"
                )
                secrets = SecretsManager("Password")
                secrets >> Edge(style="dotted") >> rds
            
            with Cluster("Streaming"):
                # Using KinesisDataStreams as a placeholder for MSK
                msk = KinesisDataStreams(
                    "MSK Cluster\n" +
                    "kafka.t3.small x2\n" +
                    "IAM Auth"
                )
            
            with Cluster("MSK Connect"):
                debezium = EC2(
                    "Debezium\nPostgres Source\n" +
                    "v2.5.4"
                )
                
                iceberg_sink = EC2(
                    "Iceberg\nKafka Sink\n" +
                    "v1.4.3"
                )
            
            endpoints = Endpoint("VPC Endpoints\n" +
                                "S3 Gateway\n" +
                                "Glue, STS, Secrets,\n" +
                                "Logs, SSM")
    
    with Cluster("Data Lake"):
        s3 = S3("S3 Bucket\n" +
               "Iceberg Tables\n" +
               "(Format v2)")
        
        glue = Glue("Glue Data\nCatalog")
        
        athena = Athena("Athena\n" +
                       "SQL Queries\n" +
                       "Time Travel")
    
    # Data flow
    rds >> Edge(label="pgoutput\nreplication", color="blue") >> debezium
    debezium >> Edge(label="Kafka topics\n(JSON)", color="green") >> msk
    msk >> Edge(label="consume", color="green") >> iceberg_sink
    iceberg_sink >> Edge(label="write\nParquet", color="purple") >> s3
    iceberg_sink >> Edge(label="register\ntables", color="purple") >> glue
    glue >> Edge(style="dotted") >> athena
    s3 >> Edge(style="dotted") >> athena
    
    # Management
    bastion >> Edge(label="SSM\nSession", style="dashed") >> rds
    endpoints >> Edge(style="dotted") >> rds
    endpoints >> Edge(style="dotted") >> msk
    endpoints >> Edge(style="dotted") >> debezium
    endpoints >> Edge(style="dotted") >> iceberg_sink

print("Architecture diagram generated: docs/architecture.png")
