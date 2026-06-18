import { useAuth } from './AuthProvider'
import LoginPage from './LoginPage'

export default function ProtectedRoute({ children }) {
  const { user, loading } = useAuth()

  if (loading) {
    return <div style={{ padding: '2rem' }}>Loading...</div>
  }

  if (!user) {
    return <LoginPage />
  }

  return children
}
