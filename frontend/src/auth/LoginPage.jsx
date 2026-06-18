import { GoogleLogin } from '@react-oauth/google'
import { useAuth } from './AuthProvider'

export default function LoginPage() {
  const { login } = useAuth()

  return (
    <div style={styles.container}>
      <div style={styles.card}>
        <h1 style={styles.title}>Aham Store</h1>
        <p style={styles.subtitle}>Sign in to access your books and documents</p>
        <GoogleLogin
          onSuccess={(response) => login(response.credential)}
          onError={() => console.error('Google sign-in failed')}
          useOneTap
          auto_select
        />
      </div>
    </div>
  )
}

const styles = {
  container: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    minHeight: '100vh',
    background: '#f5f5f5',
  },
  card: {
    background: '#fff',
    borderRadius: '12px',
    padding: '2.5rem',
    boxShadow: '0 2px 16px rgba(0,0,0,0.1)',
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: '1.25rem',
    maxWidth: '360px',
    width: '100%',
  },
  title: {
    margin: 0,
    fontSize: '1.75rem',
    fontWeight: 700,
  },
  subtitle: {
    margin: 0,
    color: '#666',
    textAlign: 'center',
    fontSize: '0.95rem',
  },
}
