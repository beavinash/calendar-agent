"""Create privacy-minimized agent turn audit table.

Revision ID: 20260716_0001
Revises:
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260716_0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
  """Create metadata-only audit storage."""

  op.create_table(
    "agent_turn_audits",
    sa.Column("id", sa.Uuid(), nullable=False),
    sa.Column("request_id", sa.Uuid(), nullable=False),
    sa.Column("device_id", sa.Uuid(), nullable=False),
    sa.Column("provider", sa.String(length=20), nullable=False),
    sa.Column("model", sa.String(length=80), nullable=False),
    sa.Column("proposal_count", sa.Integer(), nullable=False),
    sa.Column("rejected_count", sa.Integer(), nullable=False),
    sa.Column(
      "created_at",
      sa.DateTime(timezone=True),
      server_default=sa.text("now()"),
      nullable=False,
    ),
    sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
    sa.PrimaryKeyConstraint("id"),
    sa.UniqueConstraint("request_id"),
  )
  op.create_index(
    "ix_agent_turn_audits_device_id",
    "agent_turn_audits",
    ["device_id"],
  )
  op.create_index(
    "ix_agent_turn_audits_request_id",
    "agent_turn_audits",
    ["request_id"],
  )


def downgrade() -> None:
  """Remove metadata-only audit storage."""

  op.drop_index(
    "ix_agent_turn_audits_request_id",
    table_name="agent_turn_audits",
  )
  op.drop_index(
    "ix_agent_turn_audits_device_id",
    table_name="agent_turn_audits",
  )
  op.drop_table("agent_turn_audits")
