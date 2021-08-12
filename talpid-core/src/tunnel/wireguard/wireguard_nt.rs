use super::{config::Config, TunnelEvent, TunnelMetadata};
use ipnetwork::IpNetwork;
use lazy_static::lazy_static;
use std::{
    ffi::CStr,
    fmt, io, iter, mem,
    os::windows::{ffi::OsStrExt, io::RawHandle},
    path::Path,
    ptr,
    sync::{Arc, Mutex},
};
use talpid_types::ErrorExt;
use widestring::{U16CStr, U16CString};
use winapi::{
    shared::{
        guiddef::GUID,
        ifdef::NET_LUID,
        minwindef::{BOOL, FARPROC, HINSTANCE, HMODULE},
        netioapi::ConvertInterfaceLuidToGuid,
        winerror::NO_ERROR,
    },
    um::{
        libloaderapi::{
            FreeLibrary, GetProcAddress, LoadLibraryExW, LOAD_WITH_ALTERED_SEARCH_PATH,
        },
        winreg::REGSAM,
    },
};


lazy_static! {
    static ref WG_NT_DLL: Mutex<Option<Arc<WgNtDll>>> = Mutex::new(None);
    static ref ADAPTER_POOL: U16CString = U16CString::from_str("Mullvad").unwrap();
    static ref ADAPTER_ALIAS: U16CString = U16CString::from_str("Mullvad").unwrap();
}

const ADAPTER_GUID: GUID = GUID {
    Data1: 0xAFE43773,
    Data2: 0xE1F8,
    Data3: 0x4EBB,
    Data4: [0x85, 0x36, 0x57, 0x6A, 0xB8, 0x6A, 0xFE, 0x9A],
};

// type WintunOpenAdapterFn =
//    unsafe extern "stdcall" fn(pool: *const u16, name: *const u16) -> RawHandle;
type WireGuardCreateAdapterFn = unsafe extern "stdcall" fn(
    pool: *const u16,
    name: *const u16,
    requested_guid: *const GUID,
    reboot_required: *mut BOOL,
) -> RawHandle;
type WireGuardFreeAdapterFn = unsafe extern "stdcall" fn(adapter: RawHandle);
type WireGuardDeleteAdapterFn =
    unsafe extern "stdcall" fn(adapter: RawHandle, reboot_required: *mut BOOL) -> BOOL;
// type WintunGetAdapterNameFn =
//    unsafe extern "stdcall" fn(adapter: RawHandle, name: *mut u16) -> BOOL;
// type WintunGetAdapterLuidFn = unsafe extern "stdcall" fn(adapter: RawHandle, luid: *mut
// NET_LUID); type WintunLoggerCbFn = extern "stdcall" fn(WintunLoggerLevel, *const u16);
// type WintunSetLoggerFn = unsafe extern "stdcall" fn(Option<WintunLoggerCbFn>);

type RebootRequired = bool;

pub type Result<T> = std::result::Result<T, Error>;

#[derive(err_derive::Error, Debug)]
#[error(no_from)]
pub enum Error {
    /// Failed to load WireGuardNT
    #[error(display = "Failed to load wireguard.dll")]
    DllError(#[error(source)] io::Error),
    
    /// Failed to create Wintun interface
    #[error(display = "Failed to create WireGuard device")]
    CreateTunnelDeviceError(#[error(source)] io::Error),
}

pub struct WgNtTunnel {}

impl WgNtTunnel {
    pub fn start_tunnel(
        resource_dir: &Path,
        config: &Config,
        log_path: Option<&Path>,
        routes: impl Iterator<Item = IpNetwork>,
    ) -> Result<Self> {
        let dll = load_wg_nt_dll(resource_dir)?;

        let (device, reboot_required) = WgNtAdapter::create(
            dll,
            &*ADAPTER_POOL,
            &*ADAPTER_ALIAS,
            Some(ADAPTER_GUID.clone()),
        )
        .map_err(Error::CreateTunnelDeviceError)?;

        if reboot_required {
            log::warn!("You may need to reboot to finish installing WireGuardNT");
        }

        Ok(WgNtTunnel {})
    }
}


struct WgNtAdapter {
    dll_handle: Arc<WgNtDll>,
    handle: RawHandle,
}

impl fmt::Debug for WgNtAdapter {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("WgNtAdapter")
            .field("handle", &self.handle)
            .finish()
    }
}

unsafe impl Send for WgNtAdapter {}
unsafe impl Sync for WgNtAdapter {}

impl WgNtAdapter {
    fn create(
        dll_handle: Arc<WgNtDll>,
        pool: &U16CStr,
        name: &U16CStr,
        requested_guid: Option<GUID>,
    ) -> io::Result<(Self, RebootRequired)> {
        let (handle, restart_required) = dll_handle.create_adapter(pool, name, requested_guid)?;
        Ok((Self { dll_handle, handle }, restart_required))
    }

    fn delete(self) -> io::Result<RebootRequired> {
        unsafe { self.dll_handle.delete_adapter(self.handle) }
    }
}

impl Drop for WgNtAdapter {
    fn drop(&mut self) {
        unsafe { self.dll_handle.free_adapter(self.handle) };
    }
}

struct WgNtDll {
    handle: HINSTANCE,
    func_create: WireGuardCreateAdapterFn,
    func_delete: WireGuardDeleteAdapterFn,
    func_free: WireGuardFreeAdapterFn,
}

unsafe impl Send for WgNtDll {}
unsafe impl Sync for WgNtDll {}

impl WgNtDll {
    pub fn new(resource_dir: &Path) -> io::Result<Self> {
        let wg_nt_dll: Vec<u16> = resource_dir
            .join("wireguard.dll")
            .as_os_str()
            .encode_wide()
            .chain(iter::once(0u16))
            .collect();

        let handle = unsafe {
            LoadLibraryExW(
                wg_nt_dll.as_ptr(),
                ptr::null_mut(),
                LOAD_WITH_ALTERED_SEARCH_PATH,
            )
        };
        if handle == ptr::null_mut() {
            return Err(io::Error::last_os_error());
        }
        Self::new_inner(handle, Self::get_proc_address)
    }

    fn new_inner(
        handle: HMODULE,
        get_proc_fn: unsafe fn(HMODULE, &CStr) -> io::Result<FARPROC>,
    ) -> io::Result<Self> {
        Ok(WgNtDll {
            handle,
            func_create: unsafe {
                std::mem::transmute(get_proc_fn(
                    handle,
                    CStr::from_bytes_with_nul(b"WireGuardCreateAdapter\0").unwrap(),
                )?)
            },
            func_delete: unsafe {
                std::mem::transmute(get_proc_fn(
                    handle,
                    CStr::from_bytes_with_nul(b"WireGuardDeleteAdapter\0").unwrap(),
                )?)
            },
            func_free: unsafe {
                std::mem::transmute(get_proc_fn(
                    handle,
                    CStr::from_bytes_with_nul(b"WireGuardFreeAdapter\0").unwrap(),
                )?)
            },
        })
    }

    unsafe fn get_proc_address(handle: HMODULE, name: &CStr) -> io::Result<FARPROC> {
        let handle = GetProcAddress(handle, name.as_ptr());
        if handle == ptr::null_mut() {
            return Err(io::Error::last_os_error());
        }
        Ok(handle)
    }

    pub fn create_adapter(
        &self,
        pool: &U16CStr,
        name: &U16CStr,
        requested_guid: Option<GUID>,
    ) -> io::Result<(RawHandle, RebootRequired)> {
        let guid_ptr = match requested_guid.as_ref() {
            Some(guid) => guid as *const _,
            None => ptr::null_mut(),
        };
        let mut reboot_required = 0;
        let handle = unsafe {
            (self.func_create)(pool.as_ptr(), name.as_ptr(), guid_ptr, &mut reboot_required)
        };
        if handle == ptr::null_mut() {
            return Err(io::Error::last_os_error());
        }
        Ok((handle, reboot_required != 0))
    }

    pub unsafe fn delete_adapter(&self, adapter: RawHandle) -> io::Result<RebootRequired> {
        let mut reboot_required = 0;
        let result = (self.func_delete)(adapter, &mut reboot_required);
        if result == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(reboot_required != 0)
    }

    pub unsafe fn free_adapter(&self, adapter: RawHandle) {
        (self.func_free)(adapter);
    }
}

impl Drop for WgNtDll {
    fn drop(&mut self) {
        unsafe { FreeLibrary(self.handle) };
    }
}

fn load_wg_nt_dll(resource_dir: &Path) -> Result<Arc<WgNtDll>> {
    let mut dll = (*WG_NT_DLL).lock().expect("WireGuardNT mutex poisoned");
    match &*dll {
        Some(dll) => Ok(dll.clone()),
        None => {
            let new_dll = Arc::new(WgNtDll::new(resource_dir).map_err(Error::DllError)?);
            *dll = Some(new_dll.clone());
            Ok(new_dll)
        }
    }
}
