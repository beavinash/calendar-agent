"""Application exception types."""

from typing import Literal

LLMFailureCategory = Literal[
  "authentication",
  "empty_output",
  "rate_limit",
  "structured_validation",
  "timeout",
  "unknown",
  "upstream_api",
]


class CalendarAgentError(Exception):
  """Base application exception."""


class LLMConfigurationError(CalendarAgentError):
  """Raised when a requested provider cannot be configured."""


class BYOKNotAllowedError(LLMConfigurationError):
  """Raised when a client key is sent while BYOK is disabled."""


class LLMProviderError(CalendarAgentError):
  """Raised when an upstream provider call fails safely."""

  def __init__(
    self,
    message: str = "",
    *,
    failure_category: LLMFailureCategory = "unknown",
  ) -> None:
    """Store a controlled, privacy-safe failure category."""

    super().__init__(message)
    self.failure_category = failure_category


class LLMAuthenticationError(LLMProviderError):
  """Raised when a model provider rejects its credential."""

  def __init__(self, message: str = "") -> None:
    """Classify credential rejection without retaining provider details."""

    super().__init__(message, failure_category="authentication")


class InvalidPlanningRequestError(CalendarAgentError):
  """Raised before a provider call when planning bounds are invalid."""
