# Uploader

This is a standalone Rust application that watches for new photos in a directory and uploads them to the web server.

## Configuration

The uploader is configured via environment variables. You can create a `.env` file in this directory for development.

- `API_ENDPOINT`: The URL of the API endpoint to upload photos to.
- `API_KEY`: The authentication key for the API endpoint.
- `WATCH_DIRECTORY`: The directory to watch for new photos.