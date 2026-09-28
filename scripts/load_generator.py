#!/usr/bin/env python3
"""
Load generator for CDC lakehouse demo.
Inserts, updates, and deletes records at configurable rates.
"""

import argparse
import json
import random
import sys
import time
from datetime import datetime, timedelta
import boto3
import psycopg2
from psycopg2.extras import RealDictCursor


def get_terraform_outputs():
    """Parse Terraform outputs."""
    import subprocess
    try:
        result = subprocess.run(
            ['terraform', 'output', '-json'],
            cwd='terraform',
            capture_output=True,
            text=True,
            check=True
        )
        outputs = json.loads(result.stdout)
        return {k: v['value'] for k, v in outputs.items()}
    except subprocess.CalledProcessError as e:
        print(f"Error getting Terraform outputs: {e}")
        sys.exit(1)


def get_rds_password(secret_arn, region):
    """Retrieve RDS password from Secrets Manager."""
    client = boto3.client('secretsmanager', region_name=region)
    response = client.get_secret_value(SecretId=secret_arn)
    secret = json.loads(response['SecretString'])
    return secret['password']


def setup_ssm_tunnel(bastion_id, rds_host, rds_port, local_port=5433):
    """Start SSM port forwarding session."""
    import subprocess
    params = json.dumps({
        "host": [rds_host],
        "portNumber": [str(rds_port)],
        "localPortNumber": [str(local_port)]
    })

    proc = subprocess.Popen(
        [
            'aws', 'ssm', 'start-session',
            '--target', bastion_id,
            '--document-name', 'AWS-StartPortForwardingSessionToRemoteHost',
            '--parameters', params
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )

    # Wait for tunnel
    for _ in range(30):
        try:
            import socket
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            result = sock.connect_ex(('localhost', local_port))
            sock.close()
            if result == 0:
                return proc
        except Exception:
            pass
        time.sleep(1)

    print("Error: Failed to establish SSM tunnel")
    proc.kill()
    sys.exit(1)


def connect_db(host, port, database, username, password):
    """Connect to PostgreSQL."""
    return psycopg2.connect(
        host=host,
        port=port,
        database=database,
        user=username,
        password=password
    )


class LoadGenerator:
    """Generate load on the database."""

    def __init__(self, conn, rate=10, duration=60):
        self.conn = conn
        self.rate = rate
        self.duration = duration
        self.stats = {
            'inserts': 0,
            'updates': 0,
            'deletes': 0,
            'errors': 0
        }

    def insert_customer(self, cursor):
        """Insert a random customer."""
        names = ['Alex', 'Blake', 'Casey', 'Drew', 'Ellis', 'Finley', 'Gray', 'Harper']
        domains = ['example.com', 'test.com', 'demo.com']
        name = f"{random.choice(names)} {random.choice(names)}"
        email = f"{name.lower().replace(' ', '.')}_{random.randint(1000, 9999)}@{random.choice(domains)}"

        cursor.execute(
            "INSERT INTO public.customers (name, email) VALUES (%s, %s) RETURNING id",
            (name, email)
        )
        return cursor.fetchone()[0]

    def insert_order(self, cursor):
        """Insert a random order."""
        cursor.execute("SELECT id FROM public.customers ORDER BY RANDOM() LIMIT 1")
        result = cursor.fetchone()
        if not result:
            return None

        customer_id = result[0]
        total_amount = round(random.uniform(10.0, 500.0), 2)
        statuses = ['pending', 'processing', 'shipped', 'completed']
        status = random.choice(statuses)

        cursor.execute(
            "INSERT INTO public.orders (customer_id, total_amount, status) VALUES (%s, %s, %s) RETURNING id",
            (customer_id, total_amount, status)
        )
        return cursor.fetchone()[0]

    def insert_order_item(self, cursor):
        """Insert a random order item."""
        cursor.execute("SELECT id FROM public.orders ORDER BY RANDOM() LIMIT 1")
        result = cursor.fetchone()
        if not result:
            return None

        order_id = result[0]
        products = ['Widget A', 'Widget B', 'Widget C', 'Widget D', 'Widget E', 'Gadget X', 'Gadget Y']
        product_name = random.choice(products)
        quantity = random.randint(1, 10)
        unit_price = round(random.uniform(5.0, 100.0), 2)

        cursor.execute(
            "INSERT INTO public.order_items (order_id, product_name, quantity, unit_price) VALUES (%s, %s, %s, %s)",
            (order_id, product_name, quantity, unit_price)
        )
        return True

    def update_order(self, cursor):
        """Update a random order."""
        statuses = ['pending', 'processing', 'shipped', 'completed', 'cancelled']
        new_status = random.choice(statuses)

        cursor.execute(
            "UPDATE public.orders SET status = %s WHERE id IN (SELECT id FROM public.orders ORDER BY RANDOM() LIMIT 1)",
            (new_status,)
        )
        return cursor.rowcount > 0

    def delete_order_item(self, cursor):
        """Delete a random order item."""
        cursor.execute("SELECT id FROM public.order_items ORDER BY RANDOM() LIMIT 1")
        result = cursor.fetchone()
        if not result:
            return False

        cursor.execute("DELETE FROM public.order_items WHERE id = %s", (result[0],))
        return cursor.rowcount > 0

    def run(self):
        """Run the load generator."""
        print(f"Starting load generator: {self.rate} ops/sec for {self.duration} seconds")
        print("")

        start_time = time.time()
        operations = [
            (0.3, self.insert_customer, 'customer'),
            (0.3, self.insert_order, 'order'),
            (0.2, self.insert_order_item, 'order_item'),
            (0.1, self.update_order, 'update'),
            (0.1, self.delete_order_item, 'delete')
        ]

        try:
            while time.time() - start_time < self.duration:
                iter_start = time.time()

                with self.conn.cursor() as cursor:
                    # Pick operation based on weights
                    rand = random.random()
                    cumulative = 0
                    for weight, op, op_type in operations:
                        cumulative += weight
                        if rand < cumulative:
                            try:
                                result = op(cursor)
                                self.conn.commit()

                                if op_type in ['customer', 'order', 'order_item']:
                                    self.stats['inserts'] += 1
                                elif op_type == 'update':
                                    self.stats['updates'] += 1
                                elif op_type == 'delete':
                                    self.stats['deletes'] += 1
                            except Exception as e:
                                self.conn.rollback()
                                self.stats['errors'] += 1
                                if self.stats['errors'] < 5:
                                    print(f"Error: {e}")
                            break

                # Rate limiting
                elapsed = time.time() - iter_start
                sleep_time = max(0, (1.0 / self.rate) - elapsed)
                time.sleep(sleep_time)

                # Progress
                if int(time.time() - start_time) % 10 == 0:
                    print(f"Progress: {int(time.time() - start_time)}s / {self.duration}s")

        except KeyboardInterrupt:
            print("\nInterrupted by user")

        print("")
        print("=== Load Generator Summary ===")
        print(f"  Inserts: {self.stats['inserts']}")
        print(f"  Updates: {self.stats['updates']}")
        print(f"  Deletes: {self.stats['deletes']}")
        print(f"  Errors:  {self.stats['errors']}")
        print(f"  Total:   {sum(self.stats.values())}")
        print("")


def main():
    parser = argparse.ArgumentParser(description='Load generator for CDC lakehouse')
    parser.add_argument('--rate', type=int, default=10, help='Operations per second')
    parser.add_argument('--duration', type=int, default=60, help='Duration in seconds')
    args = parser.parse_args()

    print("Getting Terraform outputs...")
    outputs = get_terraform_outputs()

    rds_endpoint = outputs['rds_endpoint'].split(':')[0]
    rds_port = int(outputs['rds_port'])
    rds_database = outputs['rds_database_name']
    rds_username = outputs['rds_master_username']
    rds_secret_arn = outputs['rds_secret_arn']
    bastion_instance_id = outputs['bastion_instance_id']
    region = outputs['region']

    print("Retrieving RDS password...")
    password = get_rds_password(rds_secret_arn, region)

    print("Starting SSM tunnel...")
    local_port = 5433
    ssm_proc = setup_ssm_tunnel(bastion_instance_id, rds_endpoint, rds_port, local_port)

    try:
        print("Connecting to database...")
        conn = connect_db('localhost', local_port, rds_database, rds_username, password)

        generator = LoadGenerator(conn, rate=args.rate, duration=args.duration)
        generator.run()

        conn.close()
    finally:
        print("Cleaning up SSM tunnel...")
        ssm_proc.kill()
        ssm_proc.wait()


if __name__ == '__main__':
    main()
