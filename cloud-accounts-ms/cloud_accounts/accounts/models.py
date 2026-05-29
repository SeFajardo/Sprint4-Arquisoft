from django.db import models


class CloudAccount(models.Model):
    company_id = models.UUIDField()
    account_id = models.CharField(max_length=12)
    account_name = models.CharField(max_length=50)
    region = models.CharField(max_length=20)
    role_arn = models.CharField(max_length=255)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'cloud_accounts'
        unique_together = [('company_id', 'account_id')]


class AuditLog(models.Model):
    timestamp = models.DateTimeField(auto_now_add=True)
    source_ip = models.CharField(max_length=45, null=True, blank=True)
    endpoint = models.CharField(max_length=255, null=True, blank=True)
    status = models.CharField(max_length=50)
    reason = models.TextField(null=True, blank=True)
    payload = models.TextField(null=True, blank=True)

    class Meta:
        db_table = 'audit_log'
