import enum

from sqlalchemy import Column, Date, Enum, ForeignKey, Integer, Numeric, String

from app.db import Base


class InvoiceStatus(enum.Enum):
    DRAFT = "draft"
    ISSUED = "issued"
    PAID = "paid"
    VOID = "void"


class Invoice(Base):
    __tablename__ = "invoices"

    id = Column(Integer, primary_key=True)
    account_id = Column(Integer, ForeignKey("accounts.id"), nullable=False)
    number = Column(String(32), nullable=False)
    issue_date = Column(Date, nullable=False)
    customer_name = Column(String(200), nullable=False)
    net_amount = Column(Numeric(12, 2), nullable=False)
    currency = Column(String(3), nullable=False)
    status = Column(Enum(InvoiceStatus), nullable=False, default=InvoiceStatus.DRAFT)
