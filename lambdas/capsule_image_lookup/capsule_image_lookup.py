import json
import logging
import os
from urllib import request, error

import boto3

# Steam serves capsule art straight off its CDN at a predictable, appid-based
# path. We hit that instead of the store appdetails API, which 403s from
# datacenter IPs and has deprecated its capsule_image/header_image fields.
STEAM_CDN_BASE_URL = os.environ.get("STEAM_CDN_BASE_URL", "https://cdn.cloudflare.steamstatic.com/steam/apps")
BUCKET_NAME = os.environ["BUCKET_NAME"]

# Send a browser-like User-Agent; the default urllib UA gets 403'd.
_HEADERS = {"User-Agent": "Mozilla/5.0"}

logging.getLogger().setLevel(logging.INFO)
logger = logging.getLogger(__name__)

s3 = boto3.client("s3")


class CapsuleImageNotFound(Exception):
    """Raised when the Steam CDN has no capsule art for an app (HTTP 404)."""


def get_capsule_image_from_steam_store(steam_game_id):
    url = f"{STEAM_CDN_BASE_URL}/{steam_game_id}/capsule_616x353.jpg"

    try:
        with request.urlopen(request.Request(url, headers=_HEADERS)) as response:
            return response.read()
    except error.HTTPError as e:
        # A 404 means this app simply has no capsule art — never will, so
        # skip it rather than retrying into the DLQ. Anything else (rate
        # limits, 5xx, transient network errors) should retry.
        if e.code == 404:
            raise CapsuleImageNotFound(url) from e
        raise


def handler(event, context):
    failed_message_ids = []

    for record in event["Records"]:
        try:
            message = json.loads(record["body"])
            logger.info("Processing message: %s", message)

            if "game_data" not in message or "steam_game_id" not in message["game_data"]:
                logger.error("Unexpected message structure, skipping record %s: %s", record["messageId"], message)
                continue

            steam_game_id = message["game_data"]["steam_game_id"]

            try:
                capsule_image = get_capsule_image_from_steam_store(steam_game_id)
            except CapsuleImageNotFound:
                logger.warning("No capsule art on Steam CDN for game %s, skipping", steam_game_id)
                continue

            s3.put_object(
                Bucket=BUCKET_NAME,
                Key=f"{steam_game_id}-capsule.jpg",
                Body=capsule_image,
                ContentType="image/jpeg",
            )

            logger.info("Uploaded capsule image for game %s", steam_game_id)
        except Exception as e:
            logger.error("Failed to process record %s: %s. Body: %s", record["messageId"], e, record["body"], exc_info=True)
            failed_message_ids.append({"itemIdentifier": record["messageId"]})

    logger.info("Processed %d records, %d failed", len(event["Records"]), len(failed_message_ids))
    return {"batchItemFailures": failed_message_ids}
