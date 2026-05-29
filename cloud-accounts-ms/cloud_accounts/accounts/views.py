import json
import logging
from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from .models import CloudAccount, AuditLog
from .validators import validate_payload

logger = logging.getLogger(__name__)


def _client_ip(request):
    forwarded = request.META.get('HTTP_X_FORWARDED_FOR')
    if forwarded:
        return forwarded.split(',')[0].strip()
    return request.META.get('REMOTE_ADDR')


@csrf_exempt
def create_cloud_account(request):
    if request.method != 'POST':
        return JsonResponse({'error': 'Method not allowed'}, status=405)

    source_ip = _client_ip(request)
    endpoint = '/cloud-accounts/'

    # Parse JSON
    try:
        data = json.loads(request.body)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        AuditLog.objects.create(
            source_ip=source_ip,
            endpoint=endpoint,
            status='INVALID_JSON',
            reason=str(exc),
            payload=request.body.decode('utf-8', errors='replace')[:1000],
        )
        return JsonResponse({'error': 'Invalid JSON'}, status=400)

    # Validate fields
    errors = validate_payload(data)
    if errors:
        AuditLog.objects.create(
            source_ip=source_ip,
            endpoint=endpoint,
            status='VALIDATION_FAILED',
            reason='; '.join(errors),
            payload=json.dumps(data)[:1000],
        )
        return JsonResponse({'error': 'Validation failed', 'details': errors}, status=400)

    # Persist
    try:
        account = CloudAccount.objects.create(
            company_id=data['company_id'],
            account_id=data['account_id'],
            account_name=data['account_name'],
            region=data['region'],
            role_arn=data['role_arn'],
        )
    except Exception as exc:
        AuditLog.objects.create(
            source_ip=source_ip,
            endpoint=endpoint,
            status='DB_ERROR',
            reason=str(exc),
            payload=json.dumps(data)[:1000],
        )
        logger.error("DB error: %s", exc)
        return JsonResponse({'error': 'Database error'}, status=500)

    AuditLog.objects.create(
        source_ip=source_ip,
        endpoint=endpoint,
        status='SUCCESS',
        payload=json.dumps(data)[:1000],
    )

    return JsonResponse({'id': account.id}, status=201)
