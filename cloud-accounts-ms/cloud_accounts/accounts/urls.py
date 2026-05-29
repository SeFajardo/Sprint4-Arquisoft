from django.urls import path
from . import views

urlpatterns = [
    path('', views.create_cloud_account, name='create_cloud_account'),
]
