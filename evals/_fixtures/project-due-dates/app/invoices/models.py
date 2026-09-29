from dataclasses import dataclass
from datetime import date
from decimal import Decimal
from enum import Enum


class InvoiceStatus(str, Enum):
    DRAFT = "draft"
    ISSUED = "issued"
    PAID = "paid"


@dataclass(frozen=True)
class Customer:
    id: int
    name: str
    payment_terms_days: int | None = None


@dataclass(frozen=True)
class Invoice:
    number: str
    customer: Customer
    issue_date: date
    total: Decimal
    status: InvoiceStatus
