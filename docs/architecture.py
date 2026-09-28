#!/usr/bin/env python3
"""
Generate AWS architecture diagram for CDC lakehouse with MSK Serverless.
Requires: pip3 install diagrams graphviz
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.aws.database import RDSPostgresqlInstance
from diagrams.aws.analytics import Glue, Athena, ManagedStreamingForKafka
from diagrams.aws.storage import S3
from diagrams.aws.compute import EC2
from diagrams.aws.network import InternetGateway, Endpoint
from diagrams.aws.security import SecretsManager
import os

# Change to docs directory
os.chdir(os.path.dirname(os.path.abspath(__file__)))

graph_attr = {
    "fontsize": "13",
    "bgcolor": "white",
    "pad": "0.5",
}

with Diagram(
    "CDC Lakehouse - MSK Serverless",
    filename="architecture",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=graph_attr
):
    
    with Cluster("VPC (10.0.0.0/16) - Private CDC Infrastructure"):
        
        with Cluster("Public Subnet"):
            bastion = EC2("Bastion\n(t3.micro)\nSSM Session Manager\n+ Kafka CLI")
            igw = InternetGateway("Internet\nGateway")
            igw >> Edge(color="orange") >> bastion
        
        with Cluster("Private Subnets (2 AZs)"):
            
            with Cluster("Data Source"):
                rds = RDSPostgresqlInstance(
                    "RDS Postgres 16\n" +
                    "db.t4g.micro\n" +
                    "Logical Replication\n" +
                    "pgoutput plugin"
                )
                secrets = SecretsManager("RDS Password\n(Secrets Manager)")
                secrets >> Edge(style="dotted") >> rds
            
            with Cluster("Streaming Layer"):
                msk = ManagedStreamingForKafka(
                    "MSK Serverless\n" +
                    "Kafka 3.7.x\n" +
                    "IAM Auth (port 9098)\n" +
                    "Auto-scaling"
                )
            
            with Cluster("MSK Connect (runtime 3.7.x, Java 17)"):
                debezium = EC2(
                    "Debezium\nPostgres Source\n" +
                    "v2.7.3.Final\n" +
                    "(1 MCU)"
                )
                
                iceberg_sink = EC2(
                    "Tabular Iceberg\nKafka Sink\n" +
                    "v0.6.19\n" +
                    "(1 MCU)"
                )
            
            endpoints = Endpoint(
                "VPC Endpoints (6)\n" +
                "S3 (Gateway)\n" +
                "Glue, STS, Secrets\n" +
                "CloudWatch Logs\n" +
                "SSM (3 endpoints)"
            )
    
    with Cluster("Data Lake"):
        s3 = S3(
            "S3 Bucket\n" +
            "Iceberg Tables\n" +
            "(Format v2, Upsert)"
        )
        
        glue = Glue("Glue Data\nCatalog")
        
        athena = Athena(
            "Athena\n" +
            "SQL Queries\n" +
            "Time Travel"
        )
    
    # Data flow (main path)
    rds >> Edge(label="1. pgoutput\nreplication", color="blue", style="bold") >> debezium
    debezium >> Edge(label="2. CDC events\n(JSON)", color="green", style="bold") >> msk
    msk >> Edge(label="3. consume", color="green", style="bold") >> iceberg_sink
    iceberg_sink >> Edge(label="4. write\nParquet", color="purple", style="bold") >> s3
    iceberg_sink >> Edge(label="5. register", color="purple") >> glue
    
    # Query path
    glue >> Edge(style="dotted", label="metadata") >> athena
    s3 >> Edge(style="dotted", label="data") >> athena
    
    # Management and setup
    bastion >> Edge(label="SSM port-forward\n(seed)", style="dashed", color="orange") >> rds
    bastion >> Edge(label="Kafka CLI\n(control topic)", style="dashed", color="orange") >> msk
    
    # VPC endpoints (dotted gray)
    endpoints >> Edge(style="dotted", color="gray") >> debezium
    endpoints >> Edge(style="dotted", color="gray") >> iceberg_sink

print("Architecture diagram generated: docs/architecture.png")
