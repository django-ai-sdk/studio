from __future__ import annotations

from typing import TYPE_CHECKING, Any

from django_ai_sdk.oversight.permissions import OversightDefaultPermission
from django_ai_sdk.permissions import (
    BasePermission,
    Operation,
    ThreadDefaultPermission,
    WorkflowDefaultPermission,
)

if TYPE_CHECKING:
    from django.contrib.auth.base_user import AbstractBaseUser
    from django.contrib.auth.models import AnonymousUser
    from django.db.models import QuerySet
    from django_ai_sdk.memories.models import Memory
    from django_ai_sdk.storage.schemas import ThreadInfo
    from django_ai_sdk.types import UserType


class DemoThreadPermission(ThreadDefaultPermission):
    async def has_object_permission(
        self,
        user: UserType,
        operation: Operation,
        obj: ThreadInfo,
        **kwargs: Any,
    ) -> bool:
        if user is None or not user.is_authenticated:
            return False

        return obj.user_id is not None and str(obj.user_id) == str(getattr(user, "pk", ""))


def is_overseer(user: UserType) -> bool:
    return bool(
        user
        and user.is_authenticated
        and (getattr(user, "is_staff", False) or getattr(user, "is_superuser", False))
    )


class StudioOversightPermission(OversightDefaultPermission):
    async def has_permission(self, user: UserType, operation: Operation, **kwargs: Any) -> bool:
        if is_overseer(user):
            return True
        return await super().has_permission(user, operation, **kwargs)


class StudioWorkflowPermission(WorkflowDefaultPermission):
    """Lets an approver decide on their own run. Demo only: drops the SDK's four-eyes rule."""

    async def has_object_permission(
        self,
        user: UserType,
        operation: Operation,
        obj: Any,
        **kwargs: Any,
    ) -> bool:
        if operation is Operation.APPROVE_WORKFLOW:
            return await self.has_permission(user, operation)
        return await super().has_object_permission(user, operation, obj, **kwargs)


class AllowAnonymousMemoryPermission(BasePermission):
    READ: frozenset[Operation] = frozenset(
        {
            Operation.VIEW_MEMORY,
            Operation.VIEW_DOCUMENT,
            Operation.LIST_DOCUMENTS,
            Operation.LIST_THREAD_MEMORIES,
            Operation.VIEW_FILE,
        }
    )
    WRITE: frozenset[Operation] = frozenset(
        {
            Operation.UPLOAD_FILE,
            Operation.DELETE_FILE,
            Operation.UPLOAD_DOCUMENT,
            Operation.DELETE_DOCUMENT,
            Operation.LINK_MEMORY,
            Operation.UNLINK_MEMORY,
        }
    )
    MANAGE: frozenset[Operation] = frozenset(
        {
            Operation.UPDATE_MEMORY,
            Operation.DELETE_MEMORY,
        }
    )

    async def has_permission(
        self, user: AbstractBaseUser | AnonymousUser | None, operation: Operation, **kwargs: Any
    ) -> bool:
        if user is None or not user.is_authenticated:
            return operation in self.READ
        return True

    async def has_object_permission(
        self,
        user: AbstractBaseUser | AnonymousUser | None,
        operation: Operation,
        obj: Memory,
        **kwargs: Any,
    ) -> bool:
        if user is None or not user.is_authenticated:
            return operation in self.READ and obj.is_public

        ownership = await obj.memory_users.filter(user=user).afirst()
        if ownership is None:
            return operation in self.READ and obj.is_public

        if operation in self.MANAGE:
            return ownership.can_manage
        return True

    def get_queryset_perms(
        self,
        user: UserType,
        operation: Operation,
        queryset: QuerySet,
    ) -> QuerySet:
        is_authenticated = user is not None and getattr(user, "is_authenticated", False)

        if not is_authenticated:
            return queryset.filter(is_public=True) if operation in self.READ else queryset.none()
        if operation in self.READ:
            return queryset.filter(is_public=True) | queryset.filter(memory_users__user=user)
        if operation in self.WRITE or operation in self.MANAGE:
            return queryset.filter(memory_users__user=user)

        return queryset.none()
