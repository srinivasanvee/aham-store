import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { GoogleOAuthProvider } from '@react-oauth/google'
import { AuthProvider } from './auth/AuthProvider'
import App from './App'

const clientId = import.meta.env.VITE_GOOGLE_CLIENT_ID
if (!clientId) {
  throw new Error('VITE_GOOGLE_CLIENT_ID is not set. Copy .env.example to .env and fill it in.')
}

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <GoogleOAuthProvider clientId={clientId}>
      <AuthProvider>
        <App />
      </AuthProvider>
    </GoogleOAuthProvider>
  </StrictMode>
)
