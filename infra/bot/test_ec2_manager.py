import pytest
from unittest.mock import MagicMock, patch
from ec2_manager import EC2Manager


@pytest.fixture
def mock_ec2():
    with patch("ec2_manager.boto3") as mock_boto3:
        mock_client = MagicMock()
        mock_boto3.client.return_value = mock_client
        manager = EC2Manager(region="us-east-1", launch_template="test-template")
        yield manager, mock_client


def test_launch_spot_instance(mock_ec2):
    manager, client = mock_ec2
    client.describe_instances.return_value = {"Reservations": []}
    client.run_instances.return_value = {
        "Instances": [{"InstanceId": "i-abc123", "State": {"Name": "pending"}}]
    }
    instance_id = manager.launch_spot()
    assert instance_id == "i-abc123"
    call_args = client.run_instances.call_args
    assert call_args[1]["InstanceMarketOptions"]["MarketType"] == "spot"


def test_launch_on_demand_instance(mock_ec2):
    manager, client = mock_ec2
    client.describe_instances.return_value = {"Reservations": []}
    client.run_instances.return_value = {
        "Instances": [{"InstanceId": "i-def456", "State": {"Name": "pending"}}]
    }
    instance_id = manager.launch_on_demand()
    assert instance_id == "i-def456"
    call_args = client.run_instances.call_args
    assert "InstanceMarketOptions" not in call_args[1]


def test_stop_instance(mock_ec2):
    manager, client = mock_ec2
    manager.stop("i-abc123")
    client.terminate_instances.assert_called_once_with(InstanceIds=["i-abc123"])


def test_get_running_instances(mock_ec2):
    manager, client = mock_ec2
    client.describe_instances.return_value = {
        "Reservations": [{
            "Instances": [{
                "InstanceId": "i-abc123",
                "State": {"Name": "running"},
                "LaunchTime": "2026-03-27T20:00:00Z",
                "InstanceLifecycle": "spot",
                "PublicIpAddress": "1.2.3.4",
            }]
        }]
    }
    instances = manager.get_running()
    assert len(instances) == 1
    assert instances[0]["InstanceId"] == "i-abc123"


def test_get_running_excludes_terminated(mock_ec2):
    manager, client = mock_ec2
    client.describe_instances.return_value = {
        "Reservations": [{
            "Instances": [
                {"InstanceId": "i-abc123", "State": {"Name": "running"},
                 "LaunchTime": "2026-03-27T20:00:00Z", "InstanceLifecycle": "spot"},
                {"InstanceId": "i-dead", "State": {"Name": "terminated"},
                 "LaunchTime": "2026-03-27T19:00:00Z"},
            ]
        }]
    }
    instances = manager.get_running()
    assert len(instances) == 1


def test_launch_respects_max_instances(mock_ec2):
    manager, client = mock_ec2
    manager._max_instances = 2
    client.describe_instances.return_value = {
        "Reservations": [{
            "Instances": [
                {"InstanceId": "i-1", "State": {"Name": "running"},
                 "LaunchTime": "2026-03-27T20:00:00Z", "InstanceLifecycle": "spot"},
                {"InstanceId": "i-2", "State": {"Name": "running"},
                 "LaunchTime": "2026-03-27T20:00:00Z", "InstanceLifecycle": "spot"},
            ]
        }]
    }
    with pytest.raises(RuntimeError, match="Maximum.*instances"):
        manager.launch_spot()
