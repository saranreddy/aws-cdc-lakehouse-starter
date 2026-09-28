#!/usr/bin/env python3
"""
Generate AWS architecture diagram for CDC lakehouse with MSK Serverless.
Requires: pip3 install diagrams graphviz
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.aws.database import RDSPostgresqlInstance
from diagrams.aws.analytics import Glue, Athena
from diagrams.aws.storage import S3
from diagrams.aws.compute import EC2
from diagrams.aws.network import InternetGateway, Endpoint
from diagrams.aws.security import SecretsManager
from diagrams.aws.integration import SimpleQueueServiceSqs as MSKPlaceholder
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
    
    with Cluster("VPC (10.0.0.0/16)"):
        
        with Cluster("Public Subnet"):
            bastion = EC2("Bastion\n(t3.micro)\nSSM Access")
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
            
            with Cluster("Streaming (IAM Auth)"):
                # Using SQS icon as placeholder for MSK Serverless
                msk = MSKPlaceholder(
                    "MSK Serverless\n" +
                    "Auto-scaling\n" +
                    "IAM Auth Only"
                )
            
            with Cluster("MSK Connect (v3.7.1)"):
                debezium = EC2(
                    "Debezium\nPostgres Source\n" +
                    "v2.7.3.Final"
                )
                
                iceberg_sink = EC2(
                    "Tabular Iceberg\nKafka Sink\n" +
                    "v0.6.19"
                )
            
            endpoints = Endpoint(
                "VPC Endpoints\n" +
                "S3, Glue, STS\n" +
                "Secrets, Logs, SSM"
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
    
    # Data flow
    rds >> Edge(label="pgoutput\nreplication", color="blue", style="bold") >> debezium
    debezium >> Edge(label="CDC topics\n(JSON)", color="green", style="bold") >> msk
    msk >> Edge(label="consume", color="green", style="bold") >> iceberg_sink
    iceberg_sink >> Edge(label="Parquet\nwrites", color="purple", style="bold") >> s3
    iceberg_sink >> Edge(label="register\ntables", color="purple") >> glue
    glue >> Edge(style="dotted", label="metadata") >> athena
    s3 >> Edge(style="dotted", label="data") >> athena
    
    # Management
    bastion >> Edge(label="Port\nForward", style="dashed") >> rds
    endpoints >> Edge(style="dotted", color="gray") >> rds
    endpoints >> Edge(style="dotted", color="gray") >> msk
    endpoints >> Edge(style="dotted", color="gray") >> debezium
    endpoints >> Edge(style="dotted", color="gray") >> iceberg_sink

print("Architecture diagram generated: docs/architecture.png")
