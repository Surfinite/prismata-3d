import pytest
from datetime import datetime, timezone
from bot import format_status_message, format_cost_estimate


def test_format_status_no_instances():
    msg = format_status_message([])
    assert "No instances running" in msg


def test_format_status_one_instance():
    instances = [{
        "InstanceId": "i-abc123",
        "State": {"Name": "running"},
        "InstanceLifecycle": "spot",
        "LaunchTime": datetime(2026, 3, 27, 20, 0, 0, tzinfo=timezone.utc),
        "PublicIpAddress": "1.2.3.4",
    }]
    msg = format_status_message(instances)
    assert "i-abc123" in msg
    assert "running" in msg
    assert "spot" in msg


def test_format_status_two_instances():
    instances = [
        {"InstanceId": "i-1", "State": {"Name": "running"},
         "InstanceLifecycle": "spot",
         "LaunchTime": datetime(2026, 3, 27, 20, 0, 0, tzinfo=timezone.utc)},
        {"InstanceId": "i-2", "State": {"Name": "pending"},
         "LaunchTime": datetime(2026, 3, 27, 20, 30, 0, tzinfo=timezone.utc)},
    ]
    msg = format_status_message(instances)
    assert "i-1" in msg
    assert "i-2" in msg


def test_format_cost_estimate():
    msg = format_cost_estimate(0.42, "spot")
    assert "$0.42" in msg
    msg2 = format_cost_estimate(1.50, "on-demand")
    assert "$1.50" in msg2
