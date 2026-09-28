#!/usr/bin/env python3
"""
Unit tests for the load generator.
Mocks AWS calls to test logic without credentials.
"""

import unittest
from unittest.mock import Mock, patch, MagicMock
import sys
import os

# Add scripts directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'scripts'))

from load_generator import LoadGenerator


class TestLoadGenerator(unittest.TestCase):
    """Test LoadGenerator class."""
    
    def setUp(self):
        """Set up test fixtures."""
        self.mock_conn = Mock()
        self.mock_cursor = Mock()
        # Create a proper context manager mock
        self.mock_cursor_context = MagicMock()
        self.mock_cursor_context.__enter__ = Mock(return_value=self.mock_cursor)
        self.mock_cursor_context.__exit__ = Mock(return_value=False)
        self.mock_conn.cursor.return_value = self.mock_cursor_context
        
    def test_insert_customer(self):
        """Test customer insertion."""
        self.mock_cursor.fetchone.return_value = [123]
        
        generator = LoadGenerator(self.mock_conn, rate=1, duration=1)
        customer_id = generator.insert_customer(self.mock_cursor)
        
        self.assertEqual(customer_id, 123)
        self.mock_cursor.execute.assert_called_once()
        
        # Verify SQL contains INSERT INTO customers
        call_args = self.mock_cursor.execute.call_args
        sql = call_args[0][0]
        self.assertIn('INSERT INTO public.customers', sql)
        self.assertIn('name', sql)
        self.assertIn('email', sql)
    
    def test_insert_order(self):
        """Test order insertion."""
        # Mock: customer exists
        self.mock_cursor.fetchone.side_effect = [
            [1],  # Customer ID from SELECT
            [456]  # Order ID from INSERT RETURNING
        ]
        
        generator = LoadGenerator(self.mock_conn, rate=1, duration=1)
        order_id = generator.insert_order(self.mock_cursor)
        
        self.assertEqual(order_id, 456)
        self.assertEqual(self.mock_cursor.execute.call_count, 2)
        
    def test_insert_order_no_customer(self):
        """Test order insertion when no customer exists."""
        self.mock_cursor.fetchone.return_value = None
        
        generator = LoadGenerator(self.mock_conn, rate=1, duration=1)
        order_id = generator.insert_order(self.mock_cursor)
        
        self.assertIsNone(order_id)
    
    def test_update_order(self):
        """Test order update."""
        self.mock_cursor.rowcount = 1
        
        generator = LoadGenerator(self.mock_conn, rate=1, duration=1)
        result = generator.update_order(self.mock_cursor)
        
        self.assertTrue(result)
        self.mock_cursor.execute.assert_called_once()
        
        # Verify SQL contains UPDATE
        call_args = self.mock_cursor.execute.call_args
        sql = call_args[0][0]
        self.assertIn('UPDATE public.orders', sql)
    
    def test_delete_order_item(self):
        """Test order item deletion."""
        self.mock_cursor.fetchone.return_value = [789]
        self.mock_cursor.rowcount = 1
        
        generator = LoadGenerator(self.mock_conn, rate=1, duration=1)
        result = generator.delete_order_item(self.mock_cursor)
        
        self.assertTrue(result)
        self.assertEqual(self.mock_cursor.execute.call_count, 2)
    
    def test_stats_initialization(self):
        """Test stats are initialized correctly."""
        generator = LoadGenerator(self.mock_conn, rate=1, duration=1)
        
        self.assertEqual(generator.stats['inserts'], 0)
        self.assertEqual(generator.stats['updates'], 0)
        self.assertEqual(generator.stats['deletes'], 0)
        self.assertEqual(generator.stats['errors'], 0)


class TestHelperFunctions(unittest.TestCase):
    """Test module-level helper functions."""
    
    @patch('subprocess.run')
    def test_get_terraform_outputs(self, mock_run):
        """Test parsing Terraform outputs."""
        from load_generator import get_terraform_outputs
        
        mock_run.return_value.stdout = '''{
            "rds_endpoint": {"value": "test.rds.amazonaws.com:5432"},
            "rds_port": {"value": 5432},
            "rds_database_name": {"value": "testdb"}
        }'''
        
        outputs = get_terraform_outputs()
        
        self.assertEqual(outputs['rds_endpoint'], 'test.rds.amazonaws.com:5432')
        self.assertEqual(outputs['rds_port'], 5432)
        self.assertEqual(outputs['rds_database_name'], 'testdb')
    
    @patch('boto3.client')
    def test_get_rds_password(self, mock_boto_client):
        """Test fetching RDS password from Secrets Manager."""
        from load_generator import get_rds_password
        
        mock_client = Mock()
        mock_boto_client.return_value = mock_client
        mock_client.get_secret_value.return_value = {
            'SecretString': '{"password": "test_password_123"}'
        }
        
        password = get_rds_password('arn:aws:secretsmanager:us-east-1:123456789012:secret:test')
        
        self.assertEqual(password, 'test_password_123')
        mock_client.get_secret_value.assert_called_once()


if __name__ == '__main__':
    unittest.main()
