import { createContext, useContext, useEffect, useState, useCallback } from 'react'
import { googleLogout } from '@react-oauth/google'
import { setAuthToken, clearAuthToken } from '../api/client'

const AuthContext = createContext(null)

// Decode the JWT payload without verifying the signature.
// Verification is done server-side by Spring Boot.
function decodeJwt(token) {
  try {
    const payload = token.split('.')[1]
    return JSON.parse(atob(payload.replace(/-/g, '+').replace(/_/g, '/')))
  } catch {
    return null
  }
}

function isExpired(claims) {
  return claims?.exp ? Date.now() / 1000 > claims.exp : true
}

export function AuthProvider({ children }) {
  const [user, setUser] = useState(null)      // decoded JWT claims
  const [token, setToken] = useState(null)    // raw ID token string
  const [loading, setLoading] = useState(true)

  const login = useCallback((idToken) => {
    const claims = decodeJwt(idToken)
    if (!claims || isExpired(claims)) return
    setToken(idToken)
    setUser(claims)
    setAuthToken(idToken)
  }, [])

  const logout = useCallback(() => {
    googleLogout()
    clearAuthToken()
    setToken(null)
    setUser(null)
  }, [])

  // Handle 401 responses fired by the axios interceptor
  useEffect(() => {
    const handler = () => logout()
    window.addEventListener('auth:expired', handler)
    return () => window.removeEventListener('auth:expired', handler)
  }, [logout])

  // On mount, check if the token is still valid (page refresh case).
  // There is nothing persisted in localStorage intentionally — ID tokens are
  // short-lived and the Google button will silently re-authenticate via
  // One Tap if the user is still signed into Google.
  useEffect(() => {
    setLoading(false)
  }, [])

  return (
    <AuthContext.Provider value={{ user, token, loading, login, logout }}>
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth() {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth must be used inside AuthProvider')
  return ctx
}
