import boto3

def _has_always_on_true(tags) -> bool:
    if not tags:
        return False
    for t in tags:
        if t.get("Key") == "AlwaysOn" and str(t.get("Value", "")).lower() == "true":
            return True
    return False

def lambda_handler(event, context):
    ec2_client = boto3.client("ec2")
    regions = [r["RegionName"] for r in ec2_client.describe_regions()["Regions"]]

    for region in regions:
        ec2 = boto3.resource("ec2", region_name=region)
        print(f"Region: {region}")

        instances = ec2.instances.filter(
            Filters=[{"Name": "instance-state-name", "Values": ["running"]}]
        )

        for instance in instances:
            if _has_always_on_true(getattr(instance, "tags", None)):
                print(f"Skipping AlwaysOn instance: {instance.id}")
                continue

            instance.stop()
            print(f"Stopped instance: {instance.id}")