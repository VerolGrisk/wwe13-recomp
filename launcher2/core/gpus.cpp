#include "launcher_core.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <map>
#include <string>
#include <vector>

#include <volk.h>

#if defined(__APPLE__)
#include <dlfcn.h>
#include <cstring>
#endif

namespace wwe13::launcher {
namespace {

std::string DeviceId(uint32_t vendor, uint32_t device) {
  char buffer[32]{};
  std::snprintf(buffer, sizeof(buffer), "%04X:%04X", vendor, device);
  return buffer;
}

std::string Lower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
    return static_cast<char>(std::tolower(ch));
  });
  return value;
}

#if defined(__APPLE__)
// volkInitialize() only dlopens bare names, which do not search Homebrew's prefix or an app
// bundle. Try the places the game also looks (rex/platform/dynlib.h kVulkanLoaderFallbacks).
bool InitializeVulkanLoader() {
  if (volkInitialize() == VK_SUCCESS) return true;
  static const char* const kCandidates[] = {
      "@executable_path/libvulkan.1.dylib",
      "@executable_path/../Frameworks/libvulkan.1.dylib",
      "/opt/homebrew/lib/libvulkan.1.dylib",
      "/usr/local/lib/libvulkan.1.dylib",
  };
  for (const char* candidate : kCandidates) {
    void* library = dlopen(candidate, RTLD_NOW | RTLD_LOCAL);
    if (!library) continue;
    auto get_instance_proc_addr =
        reinterpret_cast<PFN_vkGetInstanceProcAddr>(dlsym(library, "vkGetInstanceProcAddr"));
    if (get_instance_proc_addr) {
      // Kept loaded for the process lifetime, like the loader volk opens itself.
      volkInitializeCustom(get_instance_proc_addr);
      return true;
    }
    dlclose(library);
  }
  return false;
}

// MoltenVK is a portability driver: the loader only lists it when the instance enables
// VK_KHR_portability_enumeration and sets the matching flag.
bool HasInstanceExtension(const char* name) {
  uint32_t count = 0;
  if (vkEnumerateInstanceExtensionProperties(nullptr, &count, nullptr) != VK_SUCCESS) return false;
  std::vector<VkExtensionProperties> extensions(count);
  if (vkEnumerateInstanceExtensionProperties(nullptr, &count, extensions.data()) != VK_SUCCESS) {
    return false;
  }
  for (const VkExtensionProperties& extension : extensions) {
    if (std::strcmp(extension.extensionName, name) == 0) return true;
  }
  return false;
}
#else
bool InitializeVulkanLoader() { return volkInitialize() == VK_SUCCESS; }
#endif

}  // namespace

std::vector<GpuInfo> ListGpus() {
  std::vector<GpuInfo> result;
  if (!InitializeVulkanLoader()) return result;

  VkApplicationInfo application{};
  application.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
  application.pApplicationName = "WWE '13 PC Recompiled Launcher";
  application.applicationVersion = 1;
  application.pEngineName = "WWE '13 PC Recompiled Launcher";
  application.engineVersion = 1;
  application.apiVersion = VK_API_VERSION_1_0;
  VkInstanceCreateInfo create_info{};
  create_info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
  create_info.pApplicationInfo = &application;
#if defined(__APPLE__)
  const char* const portability_extension = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
  if (HasInstanceExtension(portability_extension)) {
    create_info.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    create_info.enabledExtensionCount = 1;
    create_info.ppEnabledExtensionNames = &portability_extension;
  }
#endif

  VkInstance instance = VK_NULL_HANDLE;
  if (vkCreateInstance(&create_info, nullptr, &instance) != VK_SUCCESS || instance == VK_NULL_HANDLE) {
    volkFinalize();
    return result;
  }
  volkLoadInstance(instance);

  uint32_t device_count = 0;
  VkResult enumerate_result = vkEnumeratePhysicalDevices(instance, &device_count, nullptr);
  if (enumerate_result == VK_SUCCESS && device_count != 0) {
    std::vector<VkPhysicalDevice> devices(device_count);
    enumerate_result = vkEnumeratePhysicalDevices(instance, &device_count, devices.data());
    if (enumerate_result == VK_SUCCESS || enumerate_result == VK_INCOMPLETE) {
      devices.resize(device_count);
      std::map<std::string, unsigned> identity_counts;
      for (size_t index = 0; index < devices.size(); ++index) {
        const VkPhysicalDevice device = devices[index];
        VkPhysicalDeviceProperties properties{};
        vkGetPhysicalDeviceProperties(device, &properties);
        if (properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU) continue;
        const std::string name = properties.deviceName[0] ? properties.deviceName : "Vulkan GPU";
        const std::string lowered = Lower(name);
        if (lowered.find("llvmpipe") != std::string::npos ||
            lowered.find("lavapipe") != std::string::npos ||
            lowered.find("software rasterizer") != std::string::npos) {
          continue;
        }
        const std::string identity = DeviceId(properties.vendorID, properties.deviceID);
        ++identity_counts[identity];
        result.push_back({identity, name,
                          properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU,
                          static_cast<int>(index)});
      }
      for (auto& gpu : result) {
        if (identity_counts[gpu.id] > 1) gpu.id += ":" + std::to_string(gpu.vulkan_index);
      }
    }
  }

  vkDestroyInstance(instance, nullptr);
  volkFinalize();
  return result;
}

Recommendation RecommendedSettings(const std::vector<GpuInfo>& gpus) {
  Recommendation recommendation;
  recommendation.settings.resolution = Resolution::k720p;
  recommendation.settings.frame_rate = FrameRate::kClassic;
  recommendation.settings.anti_aliasing = AntiAliasing::kOriginal4x;
  recommendation.settings.explicit_choice = false;
  const auto discrete = std::find_if(gpus.begin(), gpus.end(), [](const GpuInfo& gpu) {
    return !gpu.integrated;
  });
  if (discrete != gpus.end()) {
    recommendation.reason = discrete->name + " - discrete graphics";
  } else if (!gpus.empty()) {
    recommendation.settings.resolution = Resolution::k480p;
    recommendation.settings.frame_rate = FrameRate::kLock30;
    recommendation.reason = gpus.front().name + " - integrated graphics";
  } else {
    recommendation.reason = "Automatic graphics settings";
  }
  return recommendation;
}

}  // namespace wwe13::launcher
