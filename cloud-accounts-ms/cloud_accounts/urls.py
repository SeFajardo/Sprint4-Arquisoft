from django.urls import path, include

urlpatterns = [
    path('cloud-accounts/', include('cloud_accounts.accounts.urls')),
]
