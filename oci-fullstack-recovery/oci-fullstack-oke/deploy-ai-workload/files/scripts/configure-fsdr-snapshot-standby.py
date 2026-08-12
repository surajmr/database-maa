#!/usr/bin/env python3
"""Create the OKE/ATP Full Stack DR configuration using snapshot standby for ATP DR drills.

This is a snapshot-standby variant and does not modify the existing FSDR script.
It creates only the requested members:

* primary DRPG: primary ATP, primary OKE cluster, and the Ollama volume group
* standby DRPG: standby ATP and standby OKE cluster

Run without arguments after writing fsdr-oke-deployment.json.  The manifest is
deployment-specific state, not a secret, and prevents this script from guessing
which resources to protect when the tenancy has multiple lab deployments.
"""

import argparse
import json
import logging
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path


DEFAULT_MANIFEST = "fsdr-oke-deployment.json"
DEFAULT_PRIMARY_REGION = "us-ashburn-1"
DEFAULT_STANDBY_REGION = "us-phoenix-1"
POLL_SECONDS = 20
POLL_TIMEOUT_SECONDS = 1800

logging.basicConfig(format="%(asctime)s %(levelname)s: %(message)s")
logger = logging.getLogger("fsdr_oke")


def run_oci(*arguments, region=None):
    """Run OCI CLI safely and return its JSON response."""
    command = ["oci", *arguments]
    if region:
        command.extend(["--region", region])
    completed = subprocess.run(command, capture_output=True, text=True)
    if completed.returncode:
        raise RuntimeError(
            "OCI command failed ({}): {}".format(
                " ".join(command), completed.stderr.strip() or completed.stdout.strip()
            )
        )
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError("OCI command did not return JSON: {}".format(command)) from error


def valid_ocid(value, resource_type):
    return isinstance(value, str) and value.strip().startswith("ocid1.{}.".format(resource_type))


def required(values, name, resource_type):
    value = values.get(name)
    if not valid_ocid(value, resource_type):
        raise ValueError("{} must be an ocid1.{} OCID".format(name, resource_type))
    return value.strip()


def load_manifest(path):
    try:
        document = json.loads(Path(path).read_text())
    except FileNotFoundError as error:
        raise RuntimeError(
            "Deployment manifest {!r} was not found. Create it during the deployment "
            "workflow; do not select a random compartment or volume group.".format(path)
        ) from error
    except json.JSONDecodeError as error:
        raise RuntimeError("Deployment manifest is not valid JSON: {}".format(path)) from error
    if not isinstance(document, dict):
        raise RuntimeError("Deployment manifest must be a JSON object")
    return document


def orm_outputs(job_id, region):
    response = run_oci(
        "resource-manager", "job-output-summary", "list-job-outputs", "--job-id", job_id, region=region
    )
    return {item["output-name"]: item["output-value"] for item in response["data"]["items"]}


def merged_deployment(manifest):
    """Use manifest values first, then fill Terraform-created IDs from ORM."""
    values = dict(manifest)
    primary_region = values.get("primary_region", DEFAULT_PRIMARY_REGION)
    job_id = values.get("resource_manager_job_ocid")
    if job_id:
        values = {**orm_outputs(job_id, primary_region), **values}
    return values


def get_namespace():
    return run_oci("os", "ns", "get")["data"]


def wait_for_work_request(region, work_request_id):
    deadline = time.monotonic() + POLL_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        response = run_oci(
            "disaster-recovery", "work-request", "get", "--work-request-id", work_request_id, region=region
        )
        status = response["data"]["status"]
        if status == "SUCCEEDED":
            return
        if status in {"FAILED", "CANCELED"}:
            errors = run_oci(
                "disaster-recovery", "work-request-error", "list", "--work-request-id", work_request_id, region=region
            )
            raise RuntimeError("Work request {} {}: {}".format(work_request_id, status, errors["data"]))
        logger.info("Work request %s is %s", work_request_id, status)
        time.sleep(POLL_SECONDS)
    raise TimeoutError("Timed out waiting for work request {}".format(work_request_id))


def create_from_json(command, payload, region):
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as file:
        json.dump(payload, file)
        filename = file.name
    try:
        response = run_oci(*command, "--from-json", "file://" + filename, region=region)
    finally:
        Path(filename).unlink(missing_ok=True)
    wait_for_work_request(region, response["opc-work-request-id"])
    return response["data"]["id"]


def create_drpg(region, details):
    logger.info("Creating DR protection group %s in %s", details["displayName"], region)
    return create_from_json(("disaster-recovery", "dr-protection-group", "create"), details, region)


def create_plan(region, drpg_id, plan_type, deploy_id):
    display_name = "fsdr-rag-{}-{}".format(deploy_id, plan_type.lower().replace("_", "-"))
    logger.info("Creating %s DR plan: %s", plan_type, display_name)
    response = run_oci(
        "disaster-recovery", "dr-plan", "create",
        "--display-name", display_name,
        "--dr-protection-group-id", drpg_id,
        "--type", plan_type,
        region=region,
    )
    wait_for_work_request(region, response["opc-work-request-id"])
    logger.info("%s DR plan created: %s", plan_type, response["data"]["id"])
    return response["data"]["id"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default=os.getenv("FSDR_MANIFEST", DEFAULT_MANIFEST))
    parser.add_argument("--log-level", default="INFO")
    args = parser.parse_args()
    logger.setLevel(args.log_level.upper())

    values = merged_deployment(load_manifest(args.manifest))
    primary_region = values.get("primary_region", DEFAULT_PRIMARY_REGION)
    standby_region = values.get("standby_region", DEFAULT_STANDBY_REGION)
    compartment_id = required(values, "compartment_ocid", "compartment")
    primary_atp = required(values, "primary_adb_ocid", "autonomousdatabase")
    standby_atp = required(values, "standby_adb_ocid", "autonomousdatabase")
    primary_oke = required(values, "primary_oke_cluster_ocid", "cluster")
    standby_oke = required(values, "standby_oke_cluster_ocid", "cluster")
    ollama_group = required(values, "ollama_volume_group_ocid", "volumegroup")
    for key in ("primary_bucket", "standby_bucket", "deploy_id"):
        if not values.get(key):
            raise ValueError("{} is required in the Resource Manager outputs or manifest".format(key))

    namespace = values.get("namespace") or get_namespace()
    primary_details = {
        "compartmentId": compartment_id,
        "displayName": "fsdr-rag-primary-{}".format(values["deploy_id"]),
        "logLocation": {"namespace": namespace, "bucket": values["primary_bucket"]},
        "members": [
            {
                "memberType": "AUTONOMOUS_DATABASE",
                "memberId": primary_atp,
                "autonomousDatabaseStandbyTypeForDrDrills": "SNAPSHOT_STANDBY",
            },
            {
                "memberType": "OKE_CLUSTER", "memberId": primary_oke, "peerClusterId": standby_oke,
                "backupConfig": {"namespaces": ["ai-fsdr-lab"], "replicateImages": "DISABLE", "maxNumberOfBackupsRetained": 5},
                "backupLocation": {"namespace": namespace, "bucket": values["primary_bucket"]},
            },
            {"memberType": "VOLUME_GROUP", "memberId": ollama_group, "destinationCompartmentId": compartment_id},
        ],
    }
    standby_details = {
        "compartmentId": compartment_id,
        "displayName": "fsdr-rag-standby-{}".format(values["deploy_id"]),
        "logLocation": {"namespace": namespace, "bucket": values["standby_bucket"]},
        "members": [
            {
                "memberType": "AUTONOMOUS_DATABASE",
                "memberId": standby_atp,
                "autonomousDatabaseStandbyTypeForDrDrills": "SNAPSHOT_STANDBY",
            },
            {
                "memberType": "OKE_CLUSTER", "memberId": standby_oke, "peerClusterId": primary_oke,
                "backupConfig": {"namespaces": ["ai-fsdr-lab"], "replicateImages": "DISABLE", "maxNumberOfBackupsRetained": 5},
                "backupLocation": {"namespace": namespace, "bucket": values["standby_bucket"]},
            },
        ],
    }

    logger.info("Preparing Snapshot Standby ATP members and OKE members")
    logger.info("Creating standby DR protection group in %s", standby_region)
    standby_drpg = create_drpg(standby_region, standby_details)
    logger.info("Standby DR protection group created: %s", standby_drpg)
    logger.info("Standby DRPG members added: standby ATP and standby OKE cluster")
    primary_details["association"] = {"peerId": standby_drpg, "peerRegion": standby_region, "role": "PRIMARY"}
    logger.info("Associating primary DR protection group with standby DRPG %s", standby_drpg)
    primary_drpg = create_drpg(primary_region, primary_details)
    logger.info("Primary DR protection group created and associated: %s", primary_drpg)
    logger.info("Primary DRPG members added: primary ATP, primary OKE cluster, and Ollama volume group")
    logger.info("Creating DR plans in the standby DR protection group")
    # Create the complete plan set for this Snapshot Standby variant.
    plans = {kind: create_plan(standby_region, standby_drpg, kind, values["deploy_id"])
             for kind in ("SWITCHOVER", "FAILOVER", "START_DRILL")}
    print(json.dumps({"primary_drpg_ocid": primary_drpg, "standby_drpg_ocid": standby_drpg, "dr_plan_ocids": plans}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, TimeoutError, ValueError) as error:
        logger.error("%s", error)
        sys.exit(1)
