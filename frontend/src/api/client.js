import axios from 'axios'

const client = axios.create({
  baseURL: import.meta.env.VITE_API_URL || '',
})

// Attach the current ID token to every request.
// The token is stored in module scope and updated by AuthProvider.
let _idToken = null

export function setAuthToken(token) {
  _idToken = token
}

export function clearAuthToken() {
  _idToken = null
}

client.interceptors.request.use((config) => {
  if (_idToken) {
    config.headers.Authorization = `Bearer ${_idToken}`
  }
  return config
})

// On 401, clear the stored token so AuthProvider can redirect to login.
client.interceptors.response.use(
  (response) => response,
  (error) => {
    if (error.response?.status === 401) {
      clearAuthToken()
      window.dispatchEvent(new Event('auth:expired'))
    }
    return Promise.reject(error)
  }
)

export default client
