"""Manage EC2 spot/on-demand instances for the 3D generation pipeline."""
import boto3
from datetime import datetime, timezone


class EC2Manager:
    def __init__(
        self,
        region: str = "us-east-1",
        launch_template: str = "prismata-3d-gen",
        max_instances: int = 2,
        spot_max_price: str = "0.80",
        tag_key: str = "Project",
        tag_value: str = "prismata-3d-gen",
    ):
        self._client = boto3.client("ec2", region_name=region)
        self._launch_template = launch_template
        self._max_instances = max_instances
        self._spot_max_price = spot_max_price
        self._tag_key = tag_key
        self._tag_value = tag_value

    def _check_capacity(self) -> None:
        running = self.get_running()
        if len(running) >= self._max_instances:
            raise RuntimeError(
                f"Maximum {self._max_instances} instances already running"
            )

    def launch_spot(self) -> str:
        self._check_capacity()
        resp = self._client.run_instances(
            LaunchTemplate={"LaunchTemplateName": self._launch_template},
            MinCount=1,
            MaxCount=1,
            InstanceMarketOptions={
                "MarketType": "spot",
                "SpotOptions": {
                    "MaxPrice": self._spot_max_price,
                    "SpotInstanceType": "one-time",
                    "InstanceInterruptionBehavior": "terminate",
                },
            },
            TagSpecifications=[{
                "ResourceType": "instance",
                "Tags": [{"Key": self._tag_key, "Value": self._tag_value}],
            }],
        )
        return resp["Instances"][0]["InstanceId"]

    def launch_on_demand(self) -> str:
        self._check_capacity()
        resp = self._client.run_instances(
            LaunchTemplate={"LaunchTemplateName": self._launch_template},
            MinCount=1,
            MaxCount=1,
            TagSpecifications=[{
                "ResourceType": "instance",
                "Tags": [{"Key": self._tag_key, "Value": self._tag_value}],
            }],
        )
        return resp["Instances"][0]["InstanceId"]

    def stop(self, instance_id: str) -> None:
        self._client.terminate_instances(InstanceIds=[instance_id])

    def get_running(self) -> list[dict]:
        resp = self._client.describe_instances(
            Filters=[
                {"Name": f"tag:{self._tag_key}", "Values": [self._tag_value]},
                {"Name": "instance-state-name", "Values": ["pending", "running"]},
            ]
        )
        instances = []
        for res in resp.get("Reservations", []):
            for inst in res.get("Instances", []):
                if inst["State"]["Name"] in ("pending", "running"):
                    instances.append(inst)
        return instances

    def estimate_cost(self, instance: dict) -> float:
        launch_time = instance.get("LaunchTime")
        if isinstance(launch_time, str):
            launch_time = datetime.fromisoformat(launch_time.replace("Z", "+00:00"))
        if not launch_time:
            return 0.0
        uptime_hours = (datetime.now(timezone.utc) - launch_time).total_seconds() / 3600
        is_spot = instance.get("InstanceLifecycle") == "spot"
        hourly_rate = 0.40 if is_spot else 1.006
        return round(uptime_hours * hourly_rate, 2)
