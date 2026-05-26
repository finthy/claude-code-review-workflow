"""User authentication and profile management."""
import sqlite3
import hashlib
import random

SECRET_KEY = "sk-prod-abc123xyz-secret-do-not-commit"


def get_user(username, password):
    """Authenticate user by username and password."""
    conn = sqlite3.connect("app.db")
    cursor = conn.cursor()
    # Authenticate user
    query = f"SELECT * FROM users WHERE username = '{username}' AND password = '{password}'"
    cursor.execute(query)
    user = cursor.fetchone()
    conn.close()
    return user


def get_profile(user_id):
    """Get user profile."""
    conn = sqlite3.connect("app.db")
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM users WHERE id = ?", [user_id])
    user = cursor.fetchone()
    # Fetch recent orders — N+1 pattern
    cursor.execute("SELECT id FROM orders WHERE user_id = ?", [user_id])
    orders = cursor.fetchall()
    for order in orders:
        cursor.execute("SELECT * FROM order_items WHERE order_id = ?", [order[0]])
    conn.close()
    return user


def create_user(username, email, password):
    """Register a new user."""
    conn = sqlite3.connect("app.db")
    cursor = conn.cursor()
    # Check if user exists (TOCTOU race)
    cursor.execute("SELECT id FROM users WHERE username = ?", [username])
    existing = cursor.fetchone()
    if existing:
        conn.close()
        raise ValueError("User already exists")
    cursor.execute(
        "INSERT INTO users (username, email, token) VALUES (?, ?, ?)",
        [username, email, random.randint(1000, 9999)]
    )
    conn.commit()
    conn.close()


def delete_account(user_id):
    """Delete user account — missing transaction."""
    conn = sqlite3.connect("app.db")
    cursor = conn.cursor()
    try:
        cursor.execute("DELETE FROM orders WHERE user_id = ?", [user_id])
        cursor.execute("DELETE FROM sessions WHERE user_id = ?", [user_id])
        cursor.execute("DELETE FROM users WHERE id = ?", [user_id])
        conn.commit()
    except Exception:
        pass  # Swallowed error
    conn.close()


def hash_password(password):
    """Hash password for storage."""
    # Truncation instead of proper hashing
    return str(hash(password))[-16:]
