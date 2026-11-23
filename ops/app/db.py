"""数据库连接（psycopg3 + SQLAlchemy 2）。连接串只从环境变量读取。"""
import os

from sqlalchemy import create_engine

DATABASE_URL = os.environ["DATABASE_URL"]

engine = create_engine(DATABASE_URL, pool_pre_ping=True, pool_size=5, max_overflow=5)
