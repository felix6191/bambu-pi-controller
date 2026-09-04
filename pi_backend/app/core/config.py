"""Application configuration."""
from pydantic_settings import BaseSettings
from pydantic import Field


class Settings(BaseSettings):
    """Application settings from environment variables."""

    # Printer
    printer_host: str = Field(..., alias="PRINTER_HOST")
    printer_serial: str = Field(..., alias="PRINTER_SERIAL")
    printer_access_code: str = Field(..., alias="PRINTER_ACCESS_CODE")

    # Server
    host: str = Field("0.0.0.0", alias="HOST")
    port: int = Field(8000, alias="PORT")
    log_level: str = Field("INFO", alias="LOG_LEVEL")

    # Auth (simple token for API protection)
    api_token: str = Field(..., alias="API_TOKEN")

    # Camera (optional)
    camera_url: str | None = Field(None, alias="CAMERA_URL")
    camera_username: str | None = Field(None, alias="CAMERA_USERNAME")
    camera_password: str | None = Field(None, alias="CAMERA_PASSWORD")

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"
        extra = "ignore"


settings = Settings()