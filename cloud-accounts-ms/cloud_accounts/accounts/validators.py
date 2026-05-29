import re
import uuid

VALID_REGIONS = [
    "us-east-1", "us-east-2", "us-west-1", "us-west-2",
    "eu-west-1", "sa-east-1",
]

_ROLE_ARN_RE = re.compile(r'^arn:aws:iam::\d{12}:role/[A-Za-z0-9_+=,.@-]+$')


def validate_payload(data):
    errors = []

    company_id = data.get('company_id')
    if not company_id:
        errors.append("company_id is required")
    else:
        try:
            val = uuid.UUID(str(company_id))
            if val.version != 4:
                errors.append("company_id must be a valid UUID v4")
        except ValueError:
            errors.append("company_id must be a valid UUID v4")

    account_id = data.get('account_id')
    if not account_id:
        errors.append("account_id is required")
    elif not (isinstance(account_id, str) and re.fullmatch(r'\d{12}', account_id)):
        errors.append("account_id must be exactly 12 digits")

    account_name = data.get('account_name')
    if not account_name:
        errors.append("account_name is required")
    elif not (3 <= len(str(account_name)) <= 50):
        errors.append("account_name must be 3-50 characters")

    region = data.get('region')
    if not region:
        errors.append("region is required")
    elif region not in VALID_REGIONS:
        errors.append(f"region must be one of {VALID_REGIONS}")

    role_arn = data.get('role_arn')
    if not role_arn:
        errors.append("role_arn is required")
    elif not _ROLE_ARN_RE.match(str(role_arn)):
        errors.append("role_arn format is invalid")

    return errors
