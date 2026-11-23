"""初始 schema：orgs / sites / members / resources，含虚构种子数据。"""
import sqlalchemy as sa
from alembic import op

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None

ORG = "11111111-1111-4111-8111-111111111111"
SITE = "22222222-2222-4222-8222-222222222222"
MEMBER = "33333333-3333-4333-8333-333333333333"
RESOURCE = "44444444-4444-4444-8444-444444444444"


def _base_columns() -> list[sa.Column]:
    return [
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("org_id", sa.Uuid(), nullable=True),
        sa.Column("site_id", sa.Uuid(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("created_by", sa.String(64), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
    ]


def upgrade() -> None:
    op.create_table("orgs", *_base_columns(), sa.Column("name", sa.String(128), nullable=False))
    op.create_table("sites", *_base_columns(), sa.Column("name", sa.String(128), nullable=False))
    op.create_table("members", *_base_columns(), sa.Column("display_name", sa.String(128), nullable=False))
    op.create_table("resources", *_base_columns(), sa.Column("name", sa.String(128), nullable=False))

    op.execute(
        f"INSERT INTO orgs (id, name, created_by) VALUES ('{ORG}', '演示会员企业A', 'migration')"
    )
    op.execute(
        f"INSERT INTO sites (id, org_id, name, created_by) "
        f"VALUES ('{SITE}', '{ORG}', '演示会所-1号', 'migration')"
    )
    op.execute(
        f"INSERT INTO members (id, org_id, display_name, created_by) "
        f"VALUES ('{MEMBER}', '{ORG}', '演示会员张三', 'migration')"
    )
    op.execute(
        f"INSERT INTO resources (id, org_id, site_id, name, created_by) "
        f"VALUES ('{RESOURCE}', '{ORG}', '{SITE}', '演示会议室A', 'migration')"
    )


def downgrade() -> None:
    for table in ("resources", "members", "sites", "orgs"):
        op.drop_table(table)
