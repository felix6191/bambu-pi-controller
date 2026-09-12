"""Application configuration."""
from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import Field


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    printer_host: str = Field(default="", alias="PRINTER_HOST")
    printer_serial: str = Field(default="", alias="PRINTER_SERIAL")
    printer_access_code: str = Field(default="", alias="PRINTER_ACCESS_CODE")
    printer_port: int = Field(default=8883, alias="PRINTER_PORT")
    printer_use_tls: bool = Field(default=True, alias="PRINTER_USE_TLS")
    host: str = Field(default="0.0.0.0", alias="HOST")
    port: int = Field(default=8000, alias="PORT")
    log_level: str = Field(default="INFO", alias="LOG_LEVEL")
    api_token: str = Field(default="", alias="API_TOKEN")
    camera_url: str | None = Field(default=None, alias="CAMERA_URL")
    camera_username: str | None = Field(default=None, alias="CAMERA_USERNAME")
    camera_password: str | None = Field(default=None, alias="CAMERA_PASSWORD")
    slicer_mode: str = Field(default="orca", alias="SLICER_MODE")
    orca_profiles: str = Field(default="/opt/orcaslicer/resources/profiles/BBL", alias="ORCA_PROFILES")


settings = Settings()
