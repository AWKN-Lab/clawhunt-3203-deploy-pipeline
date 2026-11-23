"""只加不删示例：members 增加 tier 列（可空 + 默认值，向后兼容旧代码）。"""
import sqlalchemy as sa
from alembic import op

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "members",
        sa.Column("tier", sa.String(32), nullable=False, server_default=sa.text("'standard'")),
    )


def downgrade() -> None:
    op.drop_column("members", "tier")
