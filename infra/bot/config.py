"""Bot and AWS configuration. Override via environment variables."""
import os

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
INSTANCE_TYPE = os.environ.get("INSTANCE_TYPE", "g5.xlarge")
LAUNCH_TEMPLATE_NAME = os.environ.get("LAUNCH_TEMPLATE_NAME", "prismata-3d-gen")
MAX_INSTANCES = int(os.environ.get("MAX_INSTANCES", "2"))
SPOT_MAX_PRICE = os.environ.get("SPOT_MAX_PRICE", "0.80")
ON_DEMAND_PRICE_ESTIMATE = 1.006

S3_BUCKET = os.environ.get("S3_BUCKET", "prismata-3d-models")

DISCORD_TOKEN = os.environ.get("DISCORD_TOKEN", "")
DISCORD_CHANNEL_NAME = os.environ.get("DISCORD_CHANNEL_NAME", "prismata-ops")

INSTANCE_TAG_KEY = "Project"
INSTANCE_TAG_VALUE = "prismata-3d-gen"
