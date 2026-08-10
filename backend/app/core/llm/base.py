"""Provider-neutral model contract."""

from typing import Protocol

from app.schemas.agent import LLMTurn


class LLMProvider(Protocol):
  """A model provider capable of returning one structured agent turn."""

  @property
  def model(self) -> str:
    """Return the selected provider model identifier."""

  async def generate_turn(
    self,
    system_prompt: str,
    user_prompt: str,
  ) -> LLMTurn:
    """Generate a schema-validated turn without executing actions."""

  async def close(self) -> None:
    """Release request-scoped provider transports."""


class LLMProviderBuilder(Protocol):
  """Factory boundary used by the orchestration service."""

  def create(
    self,
    provider_name: str,
    requested_model: str | None,
    api_key_override: str | None,
  ) -> LLMProvider:
    """Create a configured provider for one request."""
